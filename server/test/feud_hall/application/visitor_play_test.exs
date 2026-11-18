defmodule FeudHall.Application.VisitorPlayTest do
  use FeudHall.PostgresCase
  use ExUnitProperties

  alias FeudHall.Application.{CommandWorkflow, DinerBrowse, Management, Recovery}
  alias FeudHall.Application.Projections.CounterService
  alias FeudHall.Domain.{Clock, Dietary, Identity, Market, Offers}
  alias FeudHall.Domain.Content.SliceCatalog
  alias FeudHall.Domain.Hall.{CounterPlay, Invariants}
  alias FeudHall.Domain.Hall.Management, as: HallManagement
  alias FeudHall.Infrastructure.{InMemoryEventStore, PostgresEventStore, Snapshot}

  @stall "s001"
  @recipe "falafel_wrap"
  @npc {:npc, "budget"}

  for route <- [:seed, :invitation], phase <- [:staging, :selection] do
    @route route
    @phase phase
    test "#{route} admission ends #{phase} helper work atomically and owners cannot resume it" do
      {rt, helper} = helper_with_incoming(PostgresEventStore, FeudHall.PostgresCase.fresh_store())

      rt =
        if @phase == :staging,
          do: rt |> staging() |> advance(rt.state.now + Clock.service_duration(500)),
          else: advance(rt, ready_at(rt, "first"))

      rt = client(rt, "sponsor", "sponsor-profile", :bootstrap_guest, %{name: "Sponsor"})
      sponsor = Identity.principal_for_device(Identity.get(rt.control), "sponsor")
      rt = run(rt, "seed-sponsor", {:system, :admin}, :seed_owner, %{principal: sponsor, reviewer?: true})
      rt = client(rt, "sponsor", "invite", :issue_invitation, %{})

      envelope =
        if @route == :seed do
          %{
            actor: {:system, :admin},
            command_id: "promote",
            command: {:seed_owner, %{principal: helper, reviewer?: false}}
          }
        else
          {:ok, envelope} =
            Management.envelope(rt.control, "helper", %{
              command_id: "promote",
              command: {:redeem_invitation, %{invitation_id: "I:invite"}}
            })

          envelope
        end

      position = rt.position
      snapshot = Snapshot.take(%{hall: rt.state, control: rt.control}, position)

      expected =
        div(
          (rt.state.now - rt.state.management.shifts["H:shift"].at) * rt.state.management.shifts["H:shift"].rate,
          Clock.hour()
        )

      assert {:accepted, receipt, rt} = CommandWorkflow.execute(rt, envelope)
      assert Identity.owner?(Identity.get(rt.control), helper)

      assert %{status: :ended, reason: :owner_ineligible, amount: ^expected, qualified: false} =
               rt.state.management.shifts["H:shift"]

      assert rt.state.management.shift_by_principal == %{}
      assert rt.state.management.shift_by_stall == %{}
      refute rt.state.management.selections[@stall]
      refute CounterPlay.task(rt.state, @stall)
      if expected > 0, do: assert(rt.state.wallets[helper].slices["W:H:shift"].amount == expected)

      assert {:ok, %{profile: %{work: %{active: nil, offers: [], history: [%{reason: :owner_ineligible}]}}}} =
               Management.view(rt, "helper")

      assert {:ok, %{profile: %{work: %{active: nil, offers: []}}}} = Management.view(rt, "sponsor")
      assert {:replayed, ^receipt, same} = CommandWorkflow.execute(rt, envelope)
      assert same.state == rt.state
      assert {:ok, offer} = HallManagement.shift_offer(rt.state, @stall, helper)

      # Check the role guard before task/offer validity, including forged or stale calls.
      rt =
        Enum.reduce(
          [
            :accept_helper_shift,
            :select_handover,
            :report_helper_presence,
            :start_counter_staging,
            :yield_counter_staging
          ],
          rt,
          fn kind, rt ->
            before = rt.state

            payload =
              if kind == :accept_helper_shift,
                do: Map.take(offer, [:stall_id, :rate, :quoted_at, :expires_at]),
                else: %{shift_id: "H:shift", stall_id: @stall}

            assert {:rejected, %{outcome: {:rejected, :owner_cannot_work}}, rejected} =
                     command(rt, "deny-#{kind}", {:principal, helper}, kind, payload)

            assert rejected.state == before
            rejected
          end
        )

      assert {:ok, batches} = PostgresEventStore.read_from(rt.store, position)
      assert length(batches) == 1
      assert Enum.any?(hd(batches).events, &(&1.type == :helper_shift_ended))
      assert Enum.any?(hd(batches).control_events, &(&1.type == :owner_admitted))
      assert {:ok, replay} = CommandWorkflow.open(PostgresEventStore, rt.store)
      assert {replay.state, replay.control} == {rt.state, rt.control}
      assert {:ok, %{hall: hall, control: control}} = Snapshot.restore(snapshot, batches)
      assert {hall, control} == {rt.state, rt.control}
      assert :ok = Invariants.check(rt.state)
    end
  end

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

    assert {:ok,
            %{hall: %{stalls: [%{last_service: marker}]}, profile: %{counter_pickups: [%{stall: @stall, id: marker}]}}} =
             Management.view(rt, "diner")

    assert {:ok, %{profile: %{counter_pickups: []}}} = Management.view(rt, "other")

    for device <- [nil, "other"] do
      assert {:ok, %{tasted: [], options: [%{main: @recipe}]}} = DinerBrowse.compare(rt, device, %{"new_to_me" => "1"})
    end

    rt = simulated(rt, "next-meal")

    %{ready_at: ready, service_at: served} =
      FeudHall.Domain.Kitchen.counter_forecast(rt.state, @stall)[{:tray, "T:next-meal"}]

    rt = advance(rt, ready)

    assert {:ok,
            %{hall: %{stalls: [%{last_service: ^marker, activity: %{handover: true}}]}, profile: %{counter_pickups: []}}} =
             Management.view(rt, "diner")

    assert rt.counter_services[@stall].principal == nil

    rt = advance(rt, served)

    assert {:ok, %{hall: %{stalls: [%{last_service: next_marker}]}, profile: %{counter_pickups: []}}} =
             Management.view(rt, "diner")

    assert next_marker != marker
  end

  test "checkout menu hides reserved stock while leaving the advertised menu intact" do
    rt = boot(InMemoryEventStore, InMemoryEventStore.new(), with_drink: true)
    params = %{"stall_id" => @stall, "profile_id" => "vegan"}

    assert {:ok,
            %{
              hall: %{stalls: [%{sold_out: false}]},
              checkout_menu: %{stall_id: @stall, profile_id: "vegan", mains: %{@recipe => ["mint_lemonade"]}}
            }} =
             Management.view(rt, nil, params)

    reserved = fn products ->
      update_in(rt.state.restaurants["npc-budget"].batches, fn batches ->
        Map.new(batches, fn {id, batch} ->
          {id, if(batch.product in products, do: %{batch | reserved: batch.qty}, else: batch)}
        end)
      end)
    end

    assert {:ok, %{hall: %{stalls: [%{sold_out: false}]}, checkout_menu: %{mains: %{@recipe => []}}}} =
             Management.view(reserved.(["mint"]), nil, params)

    out = reserved.(["chickpeas_dried"])

    assert {:ok, %{checkout_menu: %{mains: mains}, hall: %{stalls: [%{sold_out: true, open?: true, menu: menu}]}}} =
             Management.view(out, nil, params)

    assert mains == %{}
    assert Map.has_key?(menu, @recipe)

    assert {:ok, %{hall: %{stalls: [%{sold_out: false, open?: false}]}}} =
             Management.view(put_in(out.state.stalls[@stall].mode, :closed), nil)

    assert {:ok, %{hall: %{stalls: [%{sold_out: false, open?: false}]}}} =
             Management.view(put_in(out.state.access, :cleaning), nil)

    no_main = update_in(out.state.restaurants["npc-budget"].menu, &Map.delete(&1, @recipe))
    assert {:ok, %{hall: %{stalls: [%{sold_out: false, open?: true}]}}} = Management.view(no_main, nil)

    no_pita = reserved.(["pita"])
    assert {:ok, %{hall: %{stalls: [%{sold_out: true}]}}} = Management.view(no_pita, nil)

    packaged_pita = %{
      id: "test-pita",
      product: "pita_packaged",
      product_version: 1,
      qty: 1,
      reserved: 0,
      cost: 1,
      expires_at: rt.state.now + 1
    }

    substitute = put_in(no_pita.state.restaurants["npc-budget"].batches["test-pita"], packaged_pita)
    assert {:ok, %{hall: %{stalls: [%{sold_out: true}]}}} = Management.view(substitute, nil)

    allowed = put_in(substitute.state.restaurants["npc-budget"].policies[@recipe], %{"pita" => :prefer_primary})

    assert {:ok, %{hall: %{stalls: [%{sold_out: false}]}, checkout_menu: %{mains: %{@recipe => ["mint_lemonade"]}}}} =
             Management.view(allowed, nil, params)

    assert {:ok, %{hall: %{stalls: [%{sold_out: true}]}}} =
             Management.view(put_in(allowed.state.now, packaged_pita.expires_at), nil)
  end

  test "public stall activity counts staffed positions only while open" do
    {rt, _helper} = helper_with_incoming(InMemoryEventStore, InMemoryEventStore.new())
    assert {:ok, %{hall: %{stalls: [%{open?: true, activity: %{workers: 3}}]}}} = Management.view(rt, nil)

    rt =
      rt
      |> run("hire-on-duty", @npc, :hire_staff, %{stall_id: @stall, role: :counter, start_hour: 0, end_hour: 1})
      |> run("hire-off-duty", @npc, :hire_staff, %{stall_id: @stall, role: :counter, start_hour: 1, end_hour: 2})

    assert {:ok, %{hall: %{stalls: [%{open?: true, activity: %{workers: 4}}]}}} = Management.view(rt, nil)

    rt = run(rt, "close", @npc, :close_stall, %{stall_id: @stall})
    assert {:ok, %{hall: %{stalls: [%{open?: false, activity: %{workers: 0}}]}}} = Management.view(rt, nil)
  end

  test "reopening estimates follow the hall gate and queued staff coverage" do
    rt = boot(InMemoryEventStore, InMemoryEventStore.new())
    hour = Clock.hour()
    six = 6 * hour
    next_six = Clock.day() + six
    assert {:ok, %{hall: %{stalls: [%{open?: true, reopens_at: nil}]}}} = Management.view(rt, nil)

    rt = advance(rt, Clock.cleaning_start_of(0))
    five = Clock.cleaning_end_of(0)
    assert {:ok, %{hall: %{stalls: [%{open?: false, reopens_at: ^five}]}}} = Management.view(rt, nil)

    rt = run(rt, "manual-close", @npc, :close_stall, %{stall_id: @stall})
    assert {:ok, %{hall: %{stalls: [%{open?: false, reopens_at: nil}]}}} = Management.view(rt, nil)

    rt =
      rt
      |> run("shift-hours", @npc, :set_staff_schedule, %{stall_id: @stall, start_hour: 6, end_hour: 10})
      |> run("opening", @npc, :open_stall, %{stall_id: @stall})

    assert {:ok, %{hall: %{stalls: [%{open?: false, reopens_at: ^six}]}}} = Management.view(rt, nil)
    rt = advance(rt, five)
    assert {:ok, %{hall: %{stalls: [%{open?: false, reopens_at: ^six}]}}} = Management.view(rt, nil)
    rt = advance(rt, six)
    assert {:ok, %{hall: %{stalls: [%{open?: true, reopens_at: nil}]}}} = Management.view(rt, nil)
    rt = advance(rt, 10 * hour)
    assert {:ok, %{hall: %{stalls: [%{open?: false, reopens_at: ^next_six}]}}} = Management.view(rt, nil)
  end

  test "public handover markers publish only committed service and exclude cancellations" do
    rt = boot(InMemoryEventStore, InMemoryEventStore.new()) |> simulated("first")
    %{service_at: finish} = FeudHall.Domain.Kitchen.counter_forecast(rt.state, @stall)[{:tray, "T:first"}]
    payload = %{to_service_ms: Clock.service_ms(finish + Clock.ratio() - 1)}
    failing = %{rt | store: InMemoryEventStore.fail_next(rt.store, :before_commit)}

    assert {:error, :unavailable, failed} =
             command(failing, "serve", {:system, :scheduler}, :advance_clock, payload)

    assert failed.counter_services == %{}
    assert {:accepted, _, rt} = command(failed, "serve", {:system, :scheduler}, :advance_clock, payload)
    %{id: marker} = rt.counter_services[@stall]
    assert is_binary(marker)
    assert rt.state.trays == %{}
    assert {:ok, %{hall: %{stalls: [%{last_service: ^marker}]}}} = Management.view(rt, nil)

    next = simulated(rt, "cancelled")
    events = FeudHall.Domain.Hall.Settlement.cancel_tray(next.state, next.state.trays["T:cancelled"], :cleaning)

    {candidate, markers} =
      events
      |> Enum.with_index()
      |> Enum.reduce({next.state, next.counter_services}, fn {event, offset}, {state, markers} ->
        {FeudHall.Domain.Hall.evolve(state, event),
         CounterService.observe(markers, state, event, next.position + 1, offset)}
      end)

    markers = CounterService.retain(candidate, markers)

    assert candidate == FeudHall.Domain.Hall.replay(events, next.state)
    assert markers[@stall] == rt.counter_services[@stall]
    assert {:ok, reopened} = CommandWorkflow.open(InMemoryEventStore, rt.store)
    assert reopened.state == rt.state
    assert reopened.counter_services == %{}
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
