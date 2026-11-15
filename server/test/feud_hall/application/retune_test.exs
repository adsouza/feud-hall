defmodule FeudHall.Application.RetuneTest do
  use FeudHall.PostgresCase

  alias FeudHall.Application.{CommandWorkflow, Management, Recovery}
  alias FeudHall.Domain.{Clock, Demand, Dietary, Identity, Offers}
  alias FeudHall.Domain.Content.{LaunchCatalog, Tuning}

  alias FeudHall.Infrastructure.{
    EventCodec,
    HallAuthority,
    InMemoryEventStore,
    ManualClock,
    PostgresEventStore,
    Snapshot
  }

  @admin {:system, :admin}
  @scope "hall:test"
  # Service milliseconds in one game hour.
  @hour_service div(Clock.hour(), Clock.ratio())

  defp double(map), do: Map.new(map, fn {k, v} -> {k, v * 2} end)

  # Version 2, 180 arrivals per equivalent, every market target and cap doubled.
  defp doubled(catalog) do
    base = Tuning.of(catalog)

    %{
      base
      | version: 2,
        demand: %{base.demand | arrivals_per_equivalent: 180},
        market: %{
          target_stock_per_equivalent: double(base.market.target_stock_per_equivalent),
          replenish_cap: double(base.market.replenish_cap)
        }
    }
  end

  defp retune(tuning), do: {:retune_rules, %{tuning: tuning}}
  defp env(id, actor, command), do: %{command_id: id, actor: actor, command: command}

  # -- a managed launch hall on the command workflow ---------------------------------

  defp boot(store_mod \\ InMemoryEventStore, store \\ InMemoryEventStore.new()) do
    {:ok, rt, _} = Recovery.recover(store_mod, store, "retune", scope: @scope)
    catalog = FeudHall.Fixtures.quiet_catalog(LaunchCatalog.catalog())
    accepted(rt, @admin, :initialize_hall, %{hall_id: "h1", catalog: catalog, managed: true})
  end

  defp command(rt, actor, kind, payload, id \\ nil) do
    id = id || "retune-test-#{System.unique_integer([:positive])}"
    CommandWorkflow.execute(rt, env(id, actor, {kind, payload}))
  end

  defp accepted(rt, actor, kind, payload, id \\ nil) do
    assert {:accepted, _, rt} = command(rt, actor, kind, payload, id)
    rt
  end

  defp all_events(rt) do
    {:ok, batches} = rt.store_mod.read_from(rt.store, 0)
    Enum.flat_map(batches, & &1.events)
  end

  defp events_after(mod, store, position) do
    {:ok, batches} = mod.read_from(store, position)
    Enum.flat_map(batches, & &1.events)
  end

  defp advance(rt, to_service_ms),
    do: accepted(rt, {:system, :scheduler}, :advance_clock, %{to_service_ms: to_service_ms})

  # -- a managed launch hall under its authority, with computer-run owners --------------

  defp start_hall(store) do
    {:ok, clock} = start_supervised({ManualClock, 0})

    opts = [
      store_mod: InMemoryEventStore,
      store: store,
      owner: "node-a",
      scope: @scope,
      clock: {ManualClock, clock},
      tick_ms: :manual,
      max_gap_ms: 10 * @hour_service,
      # Only the snapshots this test takes.
      snapshot_every_events: 1_000_000_000,
      snapshot_every_service_ms: 1_000_000_000_000
    ]

    pid = start_supervised!({HallAuthority, opts})
    %{pid: pid, clock: clock}
  end

  defp tick_hours(%{pid: pid, clock: clock}, hours) do
    for _ <- 1..hours do
      ManualClock.advance(clock, @hour_service)
      assert :ok = HallAuthority.tick(pid)
    end
  end

  defp snapshot(pid) do
    s = HallAuthority.state(pid)
    {Snapshot.take(%{hall: s.hall, control: s.control}, s.position), s.position}
  end

  test "live, genesis replay and snapshot-tail replay agree across a retune" do
    hall = start_hall(InMemoryEventStore.new())
    init = %{hall_id: "h1", catalog: LaunchCatalog.catalog(), managed: true}
    assert {:accepted, _} = HallAuthority.execute(hall.pid, env("init", @admin, {:initialize_hall, init}))

    tick_hours(hall, 12)
    noon = HallAuthority.state(hall.pid)
    assert noon.hall.now == 12 * Clock.hour()
    assert map_size(noon.hall.npcs) == 3
    before_retune = snapshot(hall.pid)

    tuning = doubled(noon.hall.catalog)
    assert {:accepted, _} = HallAuthority.execute(hall.pid, env("retune:2", @admin, retune(tuning)))
    retuned_at = HallAuthority.state(hall.pid).position

    assert {:ok, [%{events: [%{type: :hall_rules_retuned, stock: top_up}]}]} =
             InMemoryEventStore.read_from(elem(HallAuthority.store(hall.pid), 1), retuned_at - 1)

    assert map_size(top_up) > 0
    tick_hours(hall, 40)

    live = HallAuthority.state(hall.pid)
    {mod, store} = HallAuthority.store(hall.pid)
    assert Tuning.of(live.hall.catalog) == tuning

    # Two midnights, simulated diners and computer-run plans after the retune.
    after_retune = events_after(mod, store, retuned_at - 1)
    assert [%{type: :hall_rules_retuned, tuning: ^tuning} | _] = after_retune
    closed = for %{type: :day_closed} = e <- after_retune, do: e
    assert length(closed) == 2
    rules = live.hall.catalog.rules.demand
    for e <- closed, do: assert(e.hour_quotas_millis == Demand.hour_quotas(rules, e.scale_millis))
    assert Enum.any?(after_retune, &(&1.type == :diner_arrived))
    assert Enum.any?(after_retune, &(&1.type == :npc_planned))

    # Every event the retuned hall records still passes the codec.
    for event <- after_retune, do: assert({:ok, ^event} = event |> EventCodec.encode!() |> EventCodec.decode())

    # Genesis replay.
    assert {:ok, genesis} = CommandWorkflow.open(mod, store)
    assert genesis.position == live.position
    assert genesis.state == live.hall
    assert genesis.control == live.control

    # A snapshot before the retune plus its tail, and a snapshot at the head with an empty tail.
    head = snapshot(hall.pid)

    for {body, position} <- [before_retune, head] do
      {:ok, tail} = mod.read_from(store, position)
      assert position == live.position == (tail == [])
      assert {:ok, restored} = Snapshot.restore(body, tail)
      assert restored.hall == live.hall
      assert restored.control == live.control
    end
  end

  test "a retried command returns the original receipt; a different payload under the same ID is refused" do
    rt = boot()
    tuning = doubled(rt.state.catalog)

    assert {:accepted, receipt, rt} = CommandWorkflow.execute(rt, env("retune:2", @admin, retune(tuning)))
    count = length(all_events(rt))
    assert Tuning.of(rt.state.catalog) == tuning

    assert {:replayed, ^receipt, again} = CommandWorkflow.execute(rt, env("retune:2", @admin, retune(tuning)))
    assert {again.state, again.position} == {rt.state, rt.position}
    assert length(all_events(again)) == count

    other = put_in(tuning.demand.arrivals_per_equivalent, 120)

    assert {:error, :command_id_conflict, refused} =
             CommandWorkflow.execute(again, env("retune:2", @admin, retune(other)))

    assert Tuning.of(refused.state.catalog) == tuning
    assert refused.position == rt.position
    assert length(all_events(refused)) == count
  end

  defp register(rt, device) do
    assert {:ok, envelope} =
             Management.envelope(rt.control, device, %{
               command_id: "register-" <> device,
               command: {:bootstrap_guest, %{name: device}}
             })

    assert {:accepted, _, rt} = CommandWorkflow.execute(rt, envelope)
    principal = Identity.principal_for_device(Identity.get(rt.control), device)
    {rt, principal}
  end

  test "only the system admin may retune" do
    rt = boot()
    {rt, visitor} = register(rt, "visitor")
    {rt, owner} = register(rt, "owner")
    rt = accepted(rt, @admin, :seed_owner, %{principal: owner, reviewer?: false})
    tuning = doubled(rt.state.catalog)

    for actor <- [{:principal, visitor}, {:principal, owner}, {:npc, "budget"}] do
      assert {:rejected, %{outcome: {:rejected, :unauthorized_or_malformed}}, after_rt} =
               command(rt, actor, :retune_rules, %{tuning: tuning})

      assert after_rt.position == rt.position
      assert after_rt.state == rt.state
    end

    assert Tuning.of(rt.state.catalog).version == 1
  end

  test "the event survives the codec" do
    launch = LaunchCatalog.catalog()
    tuning = doubled(launch)
    assert map_size(tuning.market.target_stock_per_equivalent) == map_size(launch.products)
    market = %{stock: FeudHall.Domain.Market.opening_stock(launch)}
    {:ok, [event]} = FeudHall.Domain.Hall.Retune.decide(%{catalog: launch, market: market}, tuning)
    assert map_size(event.stock) == map_size(launch.products)

    assert {:ok, decoded} = event |> EventCodec.encode!() |> EventCodec.decode()
    assert decoded == event

    # As the PostgreSQL store writes and reads it, and as a hall retuned there is reopened.
    rt = boot(PostgresEventStore, PostgresEventStore.new(Repo, @scope))
    {:ok, [expected]} = FeudHall.Domain.Hall.Retune.decide(rt.state, tuning)
    assert map_size(expected.stock) > 0
    rt = accepted(rt, @admin, :retune_rules, %{tuning: tuning}, "retune:2")
    assert {:ok, [%{events: [stored]}]} = PostgresEventStore.read_from(rt.store, rt.position - 1)
    assert stored == expected
    assert stored.tuning == tuning

    rt = advance(rt, Clock.service_ms(Clock.day()))
    assert {:ok, reopened} = CommandWorkflow.open(PostgresEventStore, rt.store)
    assert reopened.state == rt.state
    assert Tuning.of(reopened.state.catalog) == tuning
  end

  test "an accepted order placed before the retune settles on its accepted terms" do
    rt = boot()
    npc = {:npc, "budget"}
    starter = Enum.find(Map.values(rt.state.catalog.recipes), &(&1.starter and &1.cuisine == "levantine"))
    create = %{restaurant_id: "r1", stall_id: "s001", name: "Counter", cuisine: "levantine"}
    rt = accepted(rt, npc, :create_restaurant, create)

    rt =
      Enum.reduce(starter.lines, rt, fn line, rt ->
        request = %{restaurant_id: "r1", product: line.product, qty: line.qty, max_price_per_kunit: 1_000_000}
        accepted(rt, npc, :submit_purchase_request, request)
      end)

    rt = advance(rt, div(rt.state.market.next_clear_at, Clock.ratio()))
    rt = accepted(rt, npc, :open_stall, %{stall_id: "s001"})
    rt = accepted(rt, {:system, :visitor_fund}, :grant_allowance, %{principal: "guest", amount: 2_500})

    {:ok, requirement} = Dietary.requirement(rt.state.catalog, "unrestricted")
    blank = %{requirement: requirement, carbs_reserved: 0, carbs_served: 0}
    {:ok, quote} = Offers.quote_tray(rt.state, "s001", starter.id, nil, blank)
    visit = %{source: :guest, stall_id: "s001", main: starter.id, drink: nil, profile_id: "unrestricted"}
    rt = accepted(rt, {:principal, "guest"}, :admit_visit, Map.put(visit, :confirmed, Offers.terms(quote)), "guest-1")

    [accepted_tray] = for %{type: :tray_accepted} = e <- all_events(rt), do: e
    [component] = accepted_tray.components
    terms = Map.take(component, [:price, :recipe_id, :recipe_version, :funding, :lines])
    assert component.funding != [] and Enum.sum(Enum.map(component.funding, & &1.amount)) == component.price
    wallet = rt.state.wallets["guest"]
    revenue = rt.state.restaurants["r1"].ledger.revenue

    rt = accepted(rt, @admin, :retune_rules, %{tuning: doubled(rt.state.catalog)}, "retune:2")
    assert Tuning.of(rt.state.catalog).version == 2
    assert Map.take(rt.state.orders[component.order_id], Map.keys(terms)) == terms

    done = rt.state.trays[accepted_tray.tray_id].estimated_completion
    rt = advance(rt, div(done + Clock.ratio() - 1, Clock.ratio()))

    assert [%{components: [%{order_id: order_id}]}] = for(%{type: :tray_served} = e <- all_events(rt), do: e)
    assert order_id == component.order_id
    assert rt.state.restaurants["r1"].ledger.revenue == revenue + component.price

    spent = fn wallet -> wallet.slices |> Map.values() |> Enum.map(& &1.amount) |> Enum.sum() end
    assert spent.(wallet) - spent.(rt.state.wallets["guest"]) == component.price
  end
end
