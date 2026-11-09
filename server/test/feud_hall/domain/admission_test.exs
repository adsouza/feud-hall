defmodule FeudHall.Domain.AdmissionTest do
  use ExUnit.Case, async: true

  import FeudHall.Fixtures

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
end
