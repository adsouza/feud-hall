defmodule FeudHall.Application.VisitorPlayTest do
  use FeudHall.PostgresCase
  use ExUnitProperties

  alias FeudHall.Application.{CommandWorkflow, DinerBrowse, Management, Recovery}
  alias FeudHall.Domain.{Clock, Dietary, Identity, Market, Offers}
  alias FeudHall.Domain.Content.SliceCatalog
  alias FeudHall.Domain.Hall.{CounterPlay, Invariants}
  alias FeudHall.Domain.Hall.Management, as: HallManagement
  alias FeudHall.Infrastructure.{InMemoryEventStore, PostgresEventStore, Snapshot}

  @stall "s001"
  @recipe "falafel_wrap"
  @npc {:npc, "budget"}

  test "staging saves setup once, keeps ordinary payroll and replays through PostgreSQL" do
    {rt, helper} = helper_with_incoming(PostgresEventStore, FeudHall.PostgresCase.fresh_store())
    refute CounterPlay.task(rt.state, @stall)

    rt = client(rt, "other", "other-profile", :bootstrap_guest, %{name: "Other"})
    other = Identity.principal_for_device(Identity.get(rt.control), "other")

    assert {:rejected, %{outcome: {:rejected, :staging_unavailable}}, rt} =
             command(rt, "invalid", {:principal, other}, :start_counter_staging, %{shift_id: "H:shift"})

    rt = staging(rt)
    task = CounterPlay.task(rt.state, @stall)
    staged_position = rt.position
    staged_snapshot = Snapshot.take(%{hall: rt.state, control: rt.control}, staged_position)
    assert task.done_at - rt.state.now == Clock.service_duration(2_000)
    assert task.worker_id == rt.state.management.shifts["H:shift"].worker_id
    rt = advance(rt, task.done_at)
    assert CounterPlay.prepared(rt.state, @stall) == Clock.service_duration(2_000)
    assert %{tasks: 0, staged: 1} = rt.state.management.shifts["H:shift"]

    rt = advance(rt, ready_at(rt, "first"))
    assert %{selection: %{auto_item: "T:first"}} = selected_shift(rt)
    rt = select(rt, "first")
    deadline = rt.state.management.selections[@stall].deadline
    rt = advance(rt, deadline)

    ordinary = rt.state.catalog.rules.handover_ms - Clock.service_duration(5_000)
    assert rt.state.stalls[@stall].counter.done_at - deadline == ordinary - Clock.service_duration(2_000)

    refute CounterPlay.prepared(rt.state, @stall)
    rt = advance(rt, rt.state.stalls[@stall].counter.done_at)

    rt = client(rt, "helper", "heartbeat", :report_helper_presence, %{shift_id: "H:shift"})
    rt = simulated(rt, "second")
    rt = advance(rt, ready_at(rt, "second"))
    rt = client(rt, "helper", "heartbeat-ready", :report_helper_presence, %{shift_id: "H:shift"})
    rt = select(rt, "second")
    deadline = rt.state.management.selections[@stall].deadline
    rt = advance(rt, deadline)
    assert rt.state.stalls[@stall].counter.done_at - deadline == ordinary
    rt = advance(rt, rt.state.stalls[@stall].counter.done_at)
    rt = client(rt, "helper", "leave", :leave_helper_shift, %{shift_id: "H:shift"})
    shift = rt.state.management.shifts["H:shift"]
    assert %{tasks: 2, staged: 1, qualified: false} = shift
    amount = div((shift.ended_at - shift.at) * shift.rate, Clock.hour())
    assert %{amount: ^amount, reserved: 0} = rt.state.wallets[helper].slices["W:H:shift"]
    assert :ok = Invariants.check(rt.state)
    assert {:ok, replay} = CommandWorkflow.open(PostgresEventStore, rt.store)
    assert {replay.state, replay.control, replay.position} == {rt.state, rt.control, rt.position}
    assert {:ok, batches} = PostgresEventStore.read_from(rt.store, staged_position)
    assert {:ok, %{hall: hall, control: control}} = Snapshot.restore(staged_snapshot, batches)
    assert {hall, control} == {rt.state, rt.control}
  end

  property "staging transitions survive partitioned advances and never create licensing proof" do
    {initial, _} = helper_with_incoming(InMemoryEventStore, InMemoryEventStore.new())

    check all(
            mode <- member_of([:yield, :complete, :leave]),
            lead <- member_of([24_000, 48_000, 72_000]),
            parts <- list_of(integer(1..200), max_length: 6),
            max_runs: 18
          ) do
      ready = ready_at(initial, "first")
      rt = initial |> advance(ready - lead) |> staging()
      task = CounterPlay.task(rt.state, @stall)
      rt = Enum.reduce(parts, rt, &advance(&2, &2.state.now + Clock.service_duration(&1)))

      rt =
        case mode do
          :yield ->
            client(rt, "helper", "yield", :yield_counter_staging, %{shift_id: "H:shift", task_id: task.id})

          :leave ->
            client(rt, "helper", "leave", :leave_helper_shift, %{shift_id: "H:shift"})

          :complete ->
            rt
        end

      rt = advance(rt, task.done_at)
      assert rt.state.management.shifts["H:shift"][:staged] == if(mode == :complete, do: 1)
      assert rt.state.management.shifts["H:shift"].tasks == 0

      if mode != :leave do
        refute CounterPlay.task(rt.state, @stall)
        assert CounterPlay.prepared(rt.state, @stall) != nil == (mode == :complete)
      else
        refute match?(%{id: id} when id == task.id, CounterPlay.task(rt.state, @stall))
      end

      rt = advance(rt, Clock.cleaning_start_of(0))
      assert rt.state.counter_play.tasks == %{}
      assert rt.state.counter_play.prepared == %{}
      refute rt.state.management.shifts["H:shift"].qualified
      assert :ok = Invariants.check(rt.state)
      assert {:ok, replay} = CommandWorkflow.open(InMemoryEventStore, rt.store)
      assert replay.state == rt.state
    end
  end

  test "comparison uses exact tray terms and excludes only this diner’s served mains" do
    rt = boot(PostgresEventStore, FeudHall.PostgresCase.fresh_store(), with_drink: true)
    rt = client(rt, "diner", "diner-profile", :bootstrap_guest, %{name: "Diner"})
    rt = client(rt, "other", "other-profile", :bootstrap_guest, %{name: "Other"})
    rt = client(rt, "diner", "wallet", :request_allowance, %{})
    assert {:ok, %{options: [row], tasted: []}} = DinerBrowse.compare(rt, "diner", %{"profile_id" => "vegan"})
    assert row.main == @recipe
    assert row.drink == nil

    assert {:ok, %{matched: 0}} =
             DinerBrowse.compare(rt, "diner", %{"budget" => to_string(String.to_integer(row.total) - 1)})

    assert {:ok, %{options: [], sold_out: []}} = DinerBrowse.compare(rt, "diner", %{"stall_id" => "s002"})

    assert {:ok, %{options: [combo]}} = DinerBrowse.compare(rt, "diner", %{"include_drink" => "1"})
    assert combo.drink

    assert {:ok, %{total: total, earliest_completion: at}} =
             Management.quote(rt, "diner", %{
               stall_id: @stall,
               main: @recipe,
               drink: combo.drink,
               profile_id: "unrestricted"
             })

    assert {combo.total, combo.completion} == {total, at}

    assert {:ok, requirement} = Dietary.requirement(rt.state.catalog, "vegan")

    {:ok, quote} =
      Offers.quote_tray(rt.state, @stall, @recipe, nil, %{requirement: requirement, carbs_reserved: 0, carbs_served: 0})

    rt =
      client(rt, "diner", "order", :admit_visit, %{
        source: :guest,
        stall_id: @stall,
        main: @recipe,
        profile_id: "vegan",
        confirmed: Offers.terms(quote)
      })

    assert {:ok, %{tasted: []}} = DinerBrowse.compare(rt, "diner", %{})
    rt = advance(rt, quote.earliest_completion)
    assert {:ok, %{tasted: ["levantine"], options: []}} = DinerBrowse.compare(rt, "diner", %{"new_to_me" => "1"})

    for device <- [nil, "other"] do
      assert {:ok, %{tasted: [], options: [%{main: @recipe}]}} = DinerBrowse.compare(rt, device, %{"new_to_me" => "1"})
    end
  end

  defp boot(adapter, store, options \\ []) do
    {:ok, rt, _} = Recovery.recover(adapter, store, "test", scope: "hall:test")
    catalog = FeudHall.Fixtures.quiet_catalog(SliceCatalog.catalog())

    rt =
      rt
      |> run("init", {:system, :admin}, :initialize_hall, %{hall_id: "h1", catalog: catalog, managed: true})
      |> run("visitor-play", {:system, :admin}, :enable_visitor_play, %{})
      |> run("npc:budget:create", @npc, :create_restaurant, %{
        restaurant_id: "npc-budget",
        stall_id: @stall,
        name: "Counter",
        cuisine: "levantine"
      })

    rt =
      if options[:with_drink] do
        drink = %{restaurant_id: "npc-budget", stall_id: @stall, recipe_id: "mint_lemonade"}

        rt =
          rt
          |> run("unlock-drink", @npc, :unlock_recipe, drink)
          |> run("offer-drink", @npc, :set_menu_price, Map.put(drink, :price, 250))

        Enum.reduce(rt.state.catalog.recipes["mint_lemonade"].lines, rt, fn line, current ->
          price = Market.price(current.state.catalog, current.state.market, line.product)

          run(current, "stock:#{line.product}", @npc, :submit_purchase_request, %{
            restaurant_id: "npc-budget",
            product: line.product,
            qty: line.qty * 3,
            max_price_per_kunit: price
          })
        end)
      else
        rt
      end

    rt
    |> run("starter-stock", @npc, :request_starter_stock, %{restaurant_id: "npc-budget", budget: 500_000})
    |> advance(20 * Clock.minute())
    |> run("npc:budget:open", @npc, :open_stall, %{stall_id: @stall})
  end

  defp helper_with_incoming(adapter, store) do
    rt = boot(adapter, store)
    rt = client(rt, "helper", "helper-profile", :bootstrap_guest, %{name: "Helper"})
    helper = Identity.principal_for_device(Identity.get(rt.control), "helper")
    assert {:ok, offer} = HallManagement.shift_offer(rt.state, @stall, helper)

    rt =
      client(rt, "helper", "shift", :accept_helper_shift, Map.take(offer, [:stall_id, :rate, :quoted_at, :expires_at]))

    {simulated(rt, "first"), helper}
  end

  defp simulated(rt, id),
    do:
      run(rt, id, {:system, :demand}, :admit_visit, %{
        source: :simulated,
        diner_id: id,
        stall_id: @stall,
        main: @recipe,
        profile_id: "unrestricted",
        budget: 2_000
      })

  defp staging(rt), do: client(rt, "helper", "stage", :start_counter_staging, %{shift_id: "H:shift"})

  defp select(rt, id) do
    selection = rt.state.management.selections[@stall]

    client(rt, "helper", "choose-" <> id, :select_handover, %{
      shift_id: "H:shift",
      selection_id: selection.id,
      item_id: "T:" <> id,
      recipes: [@recipe]
    })
  end

  defp selected_shift(rt) do
    {:ok, %{profile: %{work: %{active: shift}}}} = Management.view(rt, "helper")
    shift
  end

  defp ready_at(rt, id) do
    %{ready_at: ready} = FeudHall.Domain.Kitchen.counter_forecast(rt.state, @stall)[{:tray, "T:" <> id}]
    ready
  end

  defp advance(rt, to) do
    to_service_ms = Clock.service_ms(to + Clock.ratio() - 1)
    run(rt, "tick:#{to_service_ms}", {:system, :scheduler}, :advance_clock, %{to_service_ms: to_service_ms})
  end

  defp client(rt, device, id, kind, payload) do
    assert {:ok, envelope} = Management.envelope(rt.control, device, %{command_id: id, command: {kind, payload}})
    assert {:accepted, _, rt} = CommandWorkflow.execute(rt, envelope)
    rt
  end

  defp run(rt, id, actor, kind, payload) do
    assert {:accepted, _, rt} = command(rt, id, actor, kind, payload)
    rt
  end

  defp command(rt, id, actor, kind, payload),
    do: CommandWorkflow.execute(rt, %{actor: actor, command_id: id, command: {kind, payload}})
end
