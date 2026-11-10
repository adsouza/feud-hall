defmodule FeudHall.Domain.AdmissionTest do
  use ExUnit.Case, async: true

  import FeudHall.Fixtures

  alias FeudHall.Domain.{Dietary, Offers}
  alias FeudHall.Domain.Hall.Admission

  setup do
    {state, _log} = stocked_world()
    %{state: state}
  end

  defp request(cap) do
    %{
      source: :simulated,
      principal: "diner:d1",
      budget: 10_000,
      stall_id: "s001",
      main: "bean_tacos",
      drink: nil,
      profile_id: "unrestricted",
      confirmed: nil,
      deadline_cap: cap
    }
  end

  defp tray_deadline({:ok, [_visit, %{type: :tray_accepted, deadline: deadline}]}), do: deadline

  test "deadline_cap lowers the bound deadline and never raises it", %{state: state} do
    uncapped = tray_deadline(Admission.admit(state, request(nil), "e1"))

    assert tray_deadline(Admission.admit(state, request(uncapped - 1), "e1")) == uncapped - 1
    assert tray_deadline(Admission.admit(state, request(uncapped + 1_000), "e1")) == uncapped
  end

  test "confirming a vegetarian quote cannot pin a different profile", %{state: state} do
    {state, _} = grant({state, []}, "guest", 1_200, "allowance")
    {:ok, requirement} = Dietary.requirement(state.catalog, "vegetarian")
    visit = %{requirement: requirement, carbs_reserved: 0, carbs_served: 0}
    assert {:ok, quote} = Offers.quote_tray(state, "s001", "bean_tacos", nil, visit)

    guest = %{request(nil) | source: :guest, principal: "guest", budget: nil, confirmed: Offers.terms(quote)}
    assert {:error, :stale_terms} = Admission.admit(state, guest, "wrong")
    guest = %{guest | profile_id: "vegetarian"}

    assert {:ok, [%{type: :visit_admitted, requirement: ^requirement}, %{type: :tray_accepted}]} =
             Admission.admit(state, guest, "right")
  end

  test "invalid legacy menu prices cannot be quoted or funded", %{state: state} do
    state = put_in(state.restaurants["r1"].menu["bean_tacos"], -900)
    assert {:error, :invalid_price} = Admission.admit(state, request(nil), "negative")
  end
end
