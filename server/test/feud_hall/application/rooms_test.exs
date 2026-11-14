defmodule FeudHall.Application.RoomsTest do
  use FeudHall.PostgresCase
  use ExUnitProperties

  alias FeudHall.Application.{CommandWorkflow, Management, Recovery}
  alias FeudHall.Domain.{Clock, Hall, Identity, PublicView}
  alias FeudHall.Domain.Npc.Planner
  alias FeudHall.Domain.Content.LaunchCatalog
  alias FeudHall.Domain.Hall.{Evolver, Invariants, Rooms}
  alias FeudHall.Domain.Hall.Management, as: HallManagement
  alias FeudHall.Infrastructure.{HallAuthority, InMemoryEventStore, ManualClock}
  alias FeudHall.Infrastructure.Diagnostics.MemorySink

  @draft_keys ~w(type principal expires_at stall_id tier rent holding setup_fee exposure)a
  @lease_keys ~w(type stall_id tier rent holding setup_fee exposure restaurant_id start_hour end_hour enabled principal at)a

  defp boot do
    {:ok, rt, _} = Recovery.recover(InMemoryEventStore, InMemoryEventStore.new(), "rooms", scope: "hall:test")

    accepted(rt, {:system, :admin}, :initialize_hall, %{
      hall_id: "h1",
      catalog: FeudHall.Fixtures.quiet_catalog(LaunchCatalog.catalog()),
      managed: true
    })
  end

  defp register(rt, device) do
    assert {:ok, envelope} =
             Management.envelope(rt.control, device, %{
               command_id: "register-" <> device,
               command: {:bootstrap_guest, %{name: device}}
             })

    assert {:accepted, _, rt} = CommandWorkflow.execute(rt, envelope)
    principal = Identity.principal_for_device(Identity.get(rt.control), device)
    rt = accepted(rt, {:system, :admin}, :seed_owner, %{principal: principal, reviewer?: false})
    {rt, principal}
  end

  defp owners(rt, devices) do
    Enum.map_reduce(devices, rt, fn device, rt ->
      {rt, principal} = register(rt, device)
      {principal, rt}
    end)
    |> then(fn {principals, rt} -> {rt, principals} end)
  end

  defp location(id, sid), do: %{restaurant_id: id, stall_id: sid, name: id, cuisine: "levantine"}

  defp command(rt, actor, kind, payload, id \\ nil) do
    id = id || "rooms-#{System.unique_integer([:positive])}"
    CommandWorkflow.execute(rt, %{command_id: id, actor: actor, command: {kind, payload}})
  end

  defp accepted(rt, actor, kind, payload) do
    assert {:accepted, _, rt} = command(rt, actor, kind, payload)
    rt
  end

  defp rejected(rt, actor, kind, payload) do
    assert {:rejected, %{outcome: {:rejected, reason}}, _} = command(rt, actor, kind, payload)
    reason
  end

  defp npc_lease(rt, sid), do: accepted(rt, {:npc, "npc-" <> sid}, :create_restaurant, location("npc-" <> sid, sid))

  defp last_events(rt) do
    {:ok, batches} = InMemoryEventStore.read_from(rt.store, rt.position - 1)
    Enum.flat_map(batches, & &1.events)
  end

  defp drafts_in(events), do: for(%{type: :stall_draft_reserved} = e <- events, do: {e.principal, e.stall_id})

  test "a reservation in a closed room is refused" do
    {rt, [first]} = owners(boot(), ["first"])
    assert rejected(rt, {:principal, first}, :reserve_stall, %{stall_id: "s005"}) == :slot_unavailable
    rt = accepted(rt, {:principal, first}, :reserve_stall, %{stall_id: "s004"})
    assert rt.state.management.drafts[first].stall_id == "s004"
  end

  test "a computer-run owner cannot be placed in a closed room" do
    rt = boot()
    assert rejected(rt, {:npc, "npc-x"}, :create_restaurant, location("npc-x", "s138")) == :room_closed
    # An unknown spot is still reported as unknown.
    assert rejected(rt, {:npc, "npc-x"}, :create_restaurant, location("npc-x", "s999")) == :unknown_slot
  end

  test "a location in a closed room is refused to an existing business" do
    rt = npc_lease(boot(), "s001")
    actor = {:npc, "npc-s001"}

    assert rejected(rt, actor, :lease_location, %{restaurant_id: "npc-s001", stall_id: "s005", cuisine: "levantine"}) ==
             :room_closed

    rt = accepted(rt, actor, :lease_location, %{restaurant_id: "npc-s001", stall_id: "s002", cuisine: "levantine"})
    assert rt.state.stalls["s002"].restaurant == "npc-s001"
  end

  test "the last prime spot opens room 2 for everyone" do
    {rt, [first]} = owners(boot(), ["first"])
    rt = rt |> npc_lease("s136") |> npc_lease("s137")
    rt = accepted(rt, {:principal, first}, :reserve_stall, %{stall_id: "s005"})
    assert rt.state.management.drafts[first].stall_id == "s005"
  end

  test "the lease records the rent it was quoted" do
    {rt, [first]} = owners(boot(), ["first"])
    assert Rooms.quote(Rooms.summary(rt.state), :prime).rent == 22_000
    rt = accepted(rt, {:principal, first}, :reserve_stall, %{stall_id: "s136"})
    assert rt.state.management.drafts[first].rent == 22_000
    rt = npc_lease(rt, "s137")
    rt = accepted(rt, {:principal, first}, :create_restaurant, location("first", "s136"))

    assert [%{rent: 22_000}] = for(%{type: :stall_leased} = e <- last_events(rt), do: e)
    assert rt.state.management.leases["s136"].rent == 22_000

    current = Rooms.quote(Rooms.summary(rt.state), :prime).rent
    assert current != 22_000
    assert HallManagement.lease_quote(rt.state, "s138").rent == current
  end

  test "an existing lease's rent is unchanged by later quotes" do
    rt = npc_lease(boot(), "s041")
    assert rt.state.management.leases["s041"].rent == 10_000
    rt = accepted(rt, {:npc, "npc-s041"}, :open_stall, %{stall_id: "s041"})
    rt = Enum.reduce(~w(s042 s043 s044 s045), rt, &npc_lease(&2, &1))

    assert rt.state.management.leases["s045"].rent != 10_000
    assert rt.state.management.leases["s041"].rent == 10_000

    rt = accepted(rt, {:system, :scheduler}, :advance_clock, %{to_service_ms: Clock.service_ms(Clock.hour())})
    {:ok, batches} = InMemoryEventStore.read_from(rt.store, 0)

    assert [charge | _] =
             for(b <- batches, %{type: :operating_costs_charged, stall_id: "s041"} = e <- b.events, do: e)

    # One open hour at 10_000 a day leaves this remainder; any other rent leaves a different one.
    assert charge.rent_accrued == rem(Clock.hour() * 10_000, Clock.day())
    assert rt.state.management.leases["s041"].rent == 10_000
  end

  test "a lease that opens a room offers it to the waiting list" do
    {rt, [first, waiting]} = owners(boot(), ["first", "waiting"])
    rt = npc_lease(rt, "s136")
    rt = accepted(rt, {:principal, first}, :reserve_stall, %{stall_id: "s137"})
    rt = accepted(rt, {:principal, waiting}, :join_waitlist, %{tiers: [:prime]})
    assert drafts_in(last_events(rt)) == []

    rt = accepted(rt, {:principal, first}, :create_restaurant, location("first", "s137"))
    events = last_events(rt)
    assert [:stall_leased] == for(%{type: :stall_leased} = e <- events, do: e.type)
    assert drafts_in(events) == [{waiting, "s138"}]
    assert rt.state.management.drafts[waiting].stall_id == "s138"
    assert :ok = Invariants.check(rt.state)
  end

  test "offers keep FIFO order and are only made in open rooms" do
    {rt, [first, earlier, later]} = owners(boot(), ["first", "earlier", "later"])
    rt = npc_lease(rt, "s136")
    rt = accepted(rt, {:principal, first}, :reserve_stall, %{stall_id: "s137"})
    rt = accepted(rt, {:principal, earlier}, :join_waitlist, %{tiers: [:prime]})
    rt = accepted(rt, {:principal, later}, :join_waitlist, %{tiers: [:prime]})

    rt = accepted(rt, {:principal, first}, :cancel_stall_draft, %{})
    assert drafts_in(last_events(rt)) == [{earlier, "s137"}]
    refute Map.has_key?(rt.state.management.drafts, later)
  end

  test "stored reservation and lease events keep exactly their fields" do
    {rt, [first]} = owners(boot(), ["first"])
    rt = accepted(rt, {:principal, first}, :reserve_stall, %{stall_id: "s001"})
    assert [draft] = for(%{type: :stall_draft_reserved} = e <- last_events(rt), do: e)
    assert Enum.sort(Map.keys(draft)) == Enum.sort(@draft_keys)

    rt = accepted(rt, {:principal, first}, :create_restaurant, location("first", "s001"))
    assert [lease] = for(%{type: :stall_leased} = e <- last_events(rt), do: e)
    assert Enum.sort(Map.keys(lease)) == Enum.sort(@lease_keys)

    rt = npc_lease(rt, "s002")
    assert [lease] = for(%{type: :stall_leased} = e <- last_events(rt), do: e)
    assert Enum.sort(Map.keys(lease)) == Enum.sort(@lease_keys)

    rt =
      accepted(rt, {:npc, "npc-s002"}, :lease_location, %{
        restaurant_id: "npc-s002",
        stall_id: "s003",
        cuisine: "levantine"
      })

    assert [lease] = for(%{type: :stall_leased} = e <- last_events(rt), do: e)
    assert Enum.sort(Map.keys(lease)) == Enum.sort(@lease_keys)
  end

  test "a new hall's three computer-run restaurants stand in room 1" do
    {:ok, clock} = start_supervised({ManualClock, 0}, id: :clock)
    {:ok, sink} = start_supervised(MemorySink, id: :sink)

    pid =
      start_supervised!(
        {HallAuthority,
         store_mod: InMemoryEventStore,
         store: InMemoryEventStore.new(),
         owner: "node-a",
         scope: "hall:test",
         clock: {ManualClock, clock},
         diagnostics: {MemorySink, sink},
         tick_ms: :manual}
      )

    catalog = FeudHall.Fixtures.quiet_catalog(LaunchCatalog.catalog())

    init = %{
      command_id: "init",
      actor: {:system, :admin},
      command: {:initialize_hall, %{hall_id: "h1", catalog: catalog, managed: true}}
    }

    assert {:accepted, _} = HallAuthority.execute(pid, init)
    hall = HallAuthority.state(pid).hall

    assert hall.stalls |> Map.keys() |> Enum.sort() == ~w(s001 s041 s042)
    rents = Map.new(hall.management.leases, fn {sid, lease} -> {sid, lease.rent} end)
    assert rents == %{"s001" => 8_000, "s041" => 10_000, "s042" => 11_000}
    assert Enum.all?(Map.keys(hall.stalls), &(Rooms.room(hall, &1) == 1))
  end

  test "computer-run owners choose only among spots in open rooms" do
    {rt, [first]} = owners(boot(), ["first"])
    rt = Enum.reduce(~w(s041 s042 s043 s044 s045), rt, &npc_lease(&2, &1))
    rt = accepted(rt, {:principal, first}, :reserve_stall, %{stall_id: "s046"})
    state = rt.state
    view = PublicView.build(state)
    premium = Enum.find(state.catalog.npc_profiles, &(&1.id == "premium"))
    assert premium.preferred_tier == :standard

    # Room 1's standard spots are all taken but one is only reserved, so room 2 stays closed.
    unfiltered = Map.reject(state.layout, fn {sid, _} -> HallManagement.reserved?(state, sid) end)
    assert Planner.choose_slot(view, unfiltered, premium) == "s047"
    assert Planner.choose_slot(view, HallManagement.npc_layout(state), premium) == "s001"
  end

  @tag :guard_sensitivity
  test "removing the guard is noticed" do
    {rt, [first]} = owners(boot(), ["first"])
    command = {:reserve_stall, %{stall_id: "s005"}}
    ctx = %{actor: {:principal, first}, command_id: "guard"}
    assert {:error, :slot_unavailable} = Hall.decide(rt.state, command, ctx)

    state = rt.state
    unguarded = update_in(state.catalog.rules, &Map.delete(&1, :rooms))
    assert {:ok, [%{type: :stall_draft_reserved, stall_id: "s005"}]} = Hall.decide(unguarded, command, ctx)
  end

  # -- property -----------------------------------------------------------------

  @devices ~w(p0 p1 p2 p3 p4 p5)
  @spots ~w(s001 s004 s005 s009 s041 s046 s047 s053 s101 s103 s104 s136 s137 s138 s139)

  property "nothing is ever placed in a room that was closed at that moment" do
    {rt, principals} = owners(boot(), @devices)
    owner = integer(0..(length(principals) - 1))
    spot = member_of(@spots)

    step =
      frequency([
        {4, tuple({constant(:reserve), owner, spot})},
        {3, tuple({constant(:confirm), owner, spot})},
        {2, tuple({constant(:cancel), owner})},
        {2, tuple({constant(:join), owner, member_of([[:quiet], [:prime], [:busy, :prime]])})},
        {3, tuple({constant(:npc), spot})},
        {2, tuple({constant(:surrender), spot})},
        {1, constant(:advance)},
        {2, tuple({constant(:fill), member_of([:quiet, :standard, :busy, :prime])})}
      ])

    check all(actions <- list_of(step, max_length: 40), max_runs: 100) do
      {last, opened} =
        actions
        |> Enum.with_index()
        |> Enum.reduce({rt, false}, fn {action, index}, {current, opened} ->
          next =
            current
            |> commands(action, index, principals)
            |> Enum.reduce(current, &run_checked(&2, &1))

          assert :ok = Invariants.check(next.state)
          {next, opened or Rooms.summary(next.state).open >= 2}
        end)

      send(self(), {:room_two_opened, opened})
      assert {:ok, replayed} = CommandWorkflow.open(InMemoryEventStore, last.store)
      assert replayed.state == last.state
    end

    outcomes = drain_outcomes([])
    assert outcomes != []
    assert Enum.count(outcomes, & &1) * 10 >= length(outcomes)
  end

  defp drain_outcomes(acc) do
    receive do
      {:room_two_opened, opened} -> drain_outcomes([opened | acc])
    after
      0 -> acc
    end
  end

  # Each action becomes zero or more `{actor, kind, payload, command_id}`, derived from the
  # state reached so far; the macro fills one class in the open rooms with NPC leases.
  defp commands(rt, action, index, principals) do
    state = rt.state
    id = "step-#{index}"

    case action do
      {:reserve, i, sid} ->
        [{{:principal, Enum.at(principals, i)}, :reserve_stall, %{stall_id: sid}, id}]

      {:confirm, i, sid} ->
        principal = Enum.at(principals, i)
        target = get_in(state.management.drafts, [principal, :stall_id]) || sid

        case state.owners[{:principal, principal}] do
          nil ->
            [{{:principal, principal}, :create_restaurant, location("r-#{index}", target), id}]

          rid ->
            payload = %{restaurant_id: rid, stall_id: target, cuisine: "levantine"}
            [{{:principal, principal}, :lease_location, payload, id}]
        end

      {:cancel, i} ->
        [{{:principal, Enum.at(principals, i)}, :cancel_stall_draft, %{}, id}]

      {:join, i, tiers} ->
        [{{:principal, Enum.at(principals, i)}, :join_waitlist, %{tiers: tiers}, id}]

      {:npc, sid} ->
        [{{:npc, "n-#{index}"}, :create_restaurant, location("n-#{index}", sid), id}]

      {:surrender, sid} ->
        case state.stalls[sid] do
          %{restaurant: rid} ->
            restaurant = state.restaurants[rid]
            [{{restaurant.owner_kind, restaurant.owner}, :surrender_location, %{restaurant_id: rid, stall_id: sid}, id}]

          nil ->
            []
        end

      :advance ->
        to = Clock.service_ms(state.now) + Clock.service_duration(10 * 60 * 1_000) + 1
        [{{:system, :scheduler}, :advance_clock, %{to_service_ms: to}, id}]

      {:fill, tier} ->
        summary = Rooms.summary(state)

        for {sid, ^tier} <- Enum.sort(state.layout),
            Rooms.open?(state, sid, summary),
            not Map.has_key?(state.stalls, sid),
            not HallManagement.reserved?(state, sid) do
          npc = "f-#{index}-#{sid}"
          {{:npc, npc}, :create_restaurant, location(npc, sid), "#{id}-#{sid}"}
        end
    end
  end

  defp run_checked(rt, {actor, kind, payload, id}) do
    case CommandWorkflow.execute(rt, %{command_id: id, actor: actor, command: {kind, payload}}) do
      {:accepted, _, next} ->
        {:ok, batches} = InMemoryEventStore.read_from(next.store, rt.position)
        assert_placed_in_open_rooms(rt.state, Enum.flat_map(batches, & &1.events))
        next

      {:rejected, _, next} ->
        assert next.state == rt.state
        next
    end
  end

  # A stall enters `state.stalls` through `restaurant_created` or `location_added`, so those
  # are checked against the state just before them (checking `stall_leased` after the stall
  # already holds a place would be vacuous).
  defp assert_placed_in_open_rooms(before, events) do
    Enum.reduce(events, before, fn event, current ->
      if event.type in [:stall_draft_reserved, :restaurant_created, :location_added, :stall_leased] do
        assert Rooms.open?(current, event.stall_id),
               "#{event.type} placed #{event.stall_id} while room #{Rooms.room(current, event.stall_id)} was closed"
      end

      Evolver.evolve(current, event)
    end)
  end
end
