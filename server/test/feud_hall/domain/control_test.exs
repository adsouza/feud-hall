defmodule FeudHall.Domain.ControlTest do
  use ExUnit.Case, async: true

  alias FeudHall.Domain.Control

  @authority {:system, :authority}
  defp ctx(actor \\ @authority), do: %{command_id: "c", actor: actor}
  defp hall, do: %{now: 96}

  defp started(epoch \\ "e1") do
    {:ok, %{control: events}} = Control.decide(nil, nil, {:start_availability, %{epoch_id: epoch}}, ctx())
    Control.replay(events)
  end

  test "no epoch means no pending recovery; start records the epoch and its recovery identity" do
    assert Control.pending_recovery_id(nil) == nil

    assert {:ok, %{control: [%{type: :availability_started, epoch_id: "e1"}], hall: []}} =
             Control.decide(nil, nil, {:start_availability, %{epoch_id: "e1"}}, ctx())

    assert Control.pending_recovery_id(started()) == "recovery:e1"
  end

  test "reconcile yields control and hall events and the identity stays pending until a newer epoch" do
    state = started()

    assert {:ok, %{control: control, hall: hall}} =
             Control.decide(state, hall(), {:reconcile_recovery, %{recovery_id: "recovery:e1"}}, ctx())

    assert control == [%{type: :availability_resumed, recovery_id: "recovery:e1", hall_ms: 96}]
    assert hall == [%{type: :hall_resumed, recovery_id: "recovery:e1"}]

    state = Control.replay(control, state)
    assert Control.pending_recovery_id(state) == "recovery:e1"

    state = Control.replay([%{type: :availability_started, epoch_id: "e2"}], state)
    assert Control.pending_recovery_id(state) == "recovery:e2"
  end

  test "a second reconcile with the same recovery id is already reconciled" do
    state = started()
    cmd = {:reconcile_recovery, %{recovery_id: "recovery:e1"}}
    {:ok, %{control: control}} = Control.decide(state, hall(), cmd, ctx())
    state = Control.replay(control, state)
    assert {:error, :already_reconciled} = Control.decide(state, hall(), cmd, ctx())
  end

  test "only the pending recovery identity may be reconciled" do
    for {state, id} <- [{started(), "recovery:e0"}, {started(), "anything"}, {nil, "recovery:e1"}] do
      assert {:error, :not_pending} = Control.decide(state, hall(), {:reconcile_recovery, %{recovery_id: id}}, ctx())
    end

    # Once a newer epoch starts, the older identity is no longer pending.
    state = Control.replay([%{type: :availability_started, epoch_id: "e2"}], started())

    assert {:error, :not_pending} =
             Control.decide(state, hall(), {:reconcile_recovery, %{recovery_id: "recovery:e1"}}, ctx())

    assert {:ok, _} = Control.decide(state, hall(), {:reconcile_recovery, %{recovery_id: "recovery:e2"}}, ctx())
  end

  test "only the authority may issue control commands" do
    for actor <- [{:system, :admin}, {:principal, "alice"}] do
      assert {:error, :forbidden} = Control.decide(nil, nil, {:start_availability, %{epoch_id: "e1"}}, ctx(actor))

      assert {:error, :forbidden} =
               Control.decide(started(), hall(), {:reconcile_recovery, %{recovery_id: "r"}}, ctx(actor))
    end
  end

  test "reconcile needs an initialised hall; a duplicate epoch and malformed payloads are rejected" do
    assert {:error, :hall_not_initialized} =
             Control.decide(started(), nil, {:reconcile_recovery, %{recovery_id: "recovery:e1"}}, ctx())

    assert {:error, :epoch_exists} = Control.decide(started(), nil, {:start_availability, %{epoch_id: "e1"}}, ctx())
    assert {:error, :invalid_command} = Control.decide(nil, nil, {:start_availability, %{epoch_id: ""}}, ctx())
    assert {:error, :invalid_command} = Control.decide(nil, hall(), {:reconcile_recovery, %{}}, ctx())
  end
end
