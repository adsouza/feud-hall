defmodule FeudHall.Web.BootstrapTest do
  use ExUnit.Case, async: false

  alias FeudHall.Domain.Content.Tuning
  alias FeudHall.Infrastructure.{HallAuthority, InMemoryEventStore, ManualClock}
  alias FeudHall.Web.Bootstrap

  @scope "hall:test"

  defp start_authority(store, owner) do
    {:ok, clock} = start_supervised({ManualClock, 0}, id: {:clock, owner})

    start_supervised!(
      {HallAuthority,
       name: FeudHall.LiveAuthority,
       store_mod: InMemoryEventStore,
       store: store,
       owner: owner,
       scope: @scope,
       clock: {ManualClock, clock},
       tick_ms: :manual},
      id: {:authority, owner}
    )
  end

  defp assert_not_retuned(pid) do
    assert Tuning.of(HallAuthority.state(pid).hall.catalog).version == 1
    {mod, store} = HallAuthority.store(pid)
    {:ok, batches} = mod.read_from(store, 0)
    types = for %{events: events} <- batches, e <- events, do: e.type
    assert :hall_initialized in types
    refute :hall_rules_retuned in types
  end

  test "booting a fresh managed hall and then an existing one never applies the customer tuning" do
    pid = start_authority(InMemoryEventStore.new(), "node-a")
    boot = start_supervised!({Bootstrap, @scope}, id: :boot_a)
    assert is_pid(boot)
    assert_not_retuned(pid)

    # The hall now exists; recover it under a new authority and boot again.
    {InMemoryEventStore, store} = HallAuthority.store(pid)
    stop_supervised!(:boot_a)
    stop_supervised!({:authority, "node-a"})

    pid = start_authority(store, "node-b")
    assert HallAuthority.state(pid).hall.management
    start_supervised!({Bootstrap, @scope}, id: :boot_b)
    assert_not_retuned(pid)
  end
end
