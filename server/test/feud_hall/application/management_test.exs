defmodule FeudHall.Application.ManagementTest do
  use FeudHall.PostgresCase
  use ExUnitProperties

  alias FeudHall.Application.{CommandWorkflow, Management, Recovery}
  alias FeudHall.Domain.{Clock, Identity}
  alias FeudHall.Domain.Content.SliceCatalog
  alias FeudHall.Domain.Hall.Invariants
  alias FeudHall.Domain.Hall.Management, as: HallManagement
  alias FeudHall.Domain.{Npc.Planner, PublicView}
  alias FeudHall.Infrastructure.{InMemoryEventStore, PostgresEventStore}

  defp boot(store_mod, store, catalog \\ SliceCatalog.catalog()) do
    {:ok, runtime, _} = Recovery.recover(store_mod, store, "test", scope: "hall:test")

    run(runtime, "init", {:system, :admin}, :initialize_hall, %{
      hall_id: "h1",
      catalog: FeudHall.Fixtures.quiet_catalog(catalog),
      managed: true
    })
  end

  defp run(rt, id, actor, kind, payload) do
    assert {:accepted, _, rt} =
             CommandWorkflow.execute(rt, %{actor: actor, command_id: id, command: {kind, payload}})

    rt
  end

  defp client(rt, device, id, kind, payload \\ %{}) do
    assert {:ok, envelope} = Management.envelope(rt.control, device, %{command_id: id, command: {kind, payload}})
    assert {:accepted, _, rt} = CommandWorkflow.execute(rt, envelope)
    rt
  end

  defp advance(rt, to), do: run(rt, "tick:#{to}", {:system, :scheduler}, :advance_clock, %{to_service_ms: to})

  defp register(rt, device, name) do
    rt = client(rt, device, "reg-" <> device, :bootstrap_guest, %{name: name})
    {rt, Identity.principal_for_device(Identity.get(rt.control), device)}
  end

  property "stall allocation traces preserve exclusive holds and compatible queue priority" do
    layout = %{"s001" => :quiet, "s041" => :standard}
    catalog = %{SliceCatalog.catalog() | layout: Enum.map(layout, fn {slot, tier} -> %{slot_id: slot, tier: tier} end)}
    devices = ~w(first second third)

    rt =
      Enum.reduce(devices, boot(InMemoryEventStore, InMemoryEventStore.new(), catalog), fn device, rt ->
        {rt, principal} = register(rt, device, device)
        run(rt, "admit:" <> device, {:system, :admin}, :seed_owner, %{principal: principal, reviewer?: false})
      end)

    actor = member_of(devices)
    slot = member_of(Enum.sort(Map.keys(layout)))

    steps =
      one_of([
        {constant(:reserve), actor, slot},
        {constant(:confirm), actor, slot},
        {constant(:cancel), actor},
        {constant(:leave), actor},
        {constant(:join), actor, member_of([[:quiet], [:standard], [:quiet, :standard]])},
        {constant(:npc), slot},
        {constant(:advance), member_of([1, 599_999, 600_000])}
      ])

    check all(
            stall <- slot,
            contender <- member_of([:direct, :waitlist]),
            tail <- list_of(steps, max_length: 20),
            max_runs: 24
          ) do
      initialized = client(rt, "first", "initial-reserve", :reserve_stall, %{stall_id: stall})
      held = %{stall => {"first", 600_000}}
      initial = %{now: 0, held: held, queue: [], leased: %{}}
      competition = if contender == :direct, do: {:reserve, "second", stall}, else: {:join, "second", [layout[stall]]}

      # Exercise a competing claim, a queued handoff, an exact expiry and an NPC
      # attempt in every run. The generated suffix explores further interleavings.
      prefix = [
        competition,
        {:join, "third", [layout[stall]]},
        {:npc, stall},
        {:cancel, "first"},
        {:advance, 600_000},
        {:confirm, "third", stall}
      ]

      {last, _} =
        Enum.reduce(Enum.with_index(prefix ++ tail), {initialized, initial}, fn {action, index}, {current, model} ->
          {outcome, model} = allocation_step(model, action, layout)
          next = run_allocation_step(current, action, "allocate:#{index}", model.now, outcome)
          assert :ok = Invariants.check(next.state)

          for device <- devices do
            assert {:ok, %{profile: profile}} = Management.view(next, device)
            draft = Enum.find(model.held, fn {_, {owner, _}} -> owner == device end)

            case draft do
              {sid, {^device, deadline}} ->
                expires_at = Clock.service_duration(deadline)
                assert %{stall_id: ^sid, expires_at: ^expires_at} = profile.draft

              nil ->
                assert profile.draft == nil
            end

            assert profile.waitlisted == List.keymember?(model.queue, device, 0)
            free = if device in Map.values(model.leased), do: [], else: free_slots(model, layout)
            assert Enum.map(profile.slots, & &1.stall_id) == free
          end

          assert Enum.sort(Map.keys(next.state.stalls)) == Enum.sort(Map.keys(model.leased))
          {next, model}
        end)

      assert {:ok, replayed} = CommandWorkflow.open(InMemoryEventStore, last.store)
      assert {replayed.position, replayed.state, replayed.control} == {last.position, last.state, last.control}
    end
  end

  defp free_slots(model, layout), do: Enum.sort(Map.keys(layout) -- (Map.keys(model.held) ++ Map.keys(model.leased)))

  defp allocation_step(model, {:advance, elapsed}, layout) do
    now = model.now + elapsed

    model =
      model.held
      |> Enum.filter(fn {_, {_, end_at}} -> end_at <= now end)
      |> Enum.sort_by(fn {_, {device, end_at}} -> {end_at, device} end)
      |> Enum.reduce(model, fn {sid, {device, end_at}}, current ->
        allocate_queued(drop_allocation(%{current | now: end_at}, sid, device), layout)
      end)

    {:accepted, %{model | now: now}}
  end

  defp allocation_step(model, action, layout) do
    case action do
      {:reserve, device, sid} ->
        if sid in free_slots(model, layout) and not has_allocation?(model, device),
          do: {:accepted, put_in(model.held[sid], {device, model.now + 600_000})},
          else: {:slot_unavailable, model}

      {:join, device, tiers} ->
        if has_allocation?(model, device) or List.keymember?(model.queue, device, 0),
          do: {:waitlist_unavailable, model},
          else: {:accepted, allocate_queued(%{model | queue: model.queue ++ [{device, tiers}]}, layout)}

      {:cancel, device} ->
        case Enum.find(model.held, fn {_, {owner, _}} -> owner == device end) do
          {sid, _} -> {:accepted, allocate_queued(drop_allocation(model, sid, device), layout)}
          nil -> {:no_draft, model}
        end

      {:leave, device} ->
        if List.keymember?(model.queue, device, 0) do
          held = Map.reject(model.held, fn {_, {owner, _}} -> owner == device end)
          model = %{model | held: held, queue: List.keydelete(model.queue, device, 0)}
          {:accepted, allocate_queued(model, layout)}
        else
          {:waitlist_unavailable, model}
        end

      {:confirm, device, sid} ->
        cond do
          device in Map.values(model.leased) ->
            {:venture_already_active, model}

          Map.has_key?(model.leased, sid) ->
            {:stall_taken, model}

          match?({^device, _}, model.held[sid]) ->
            {:accepted, put_in(drop_allocation(model, sid, device).leased[sid], device)}

          true ->
            {:slot_unavailable, model}
        end

      {:npc, sid} ->
        cond do
          Map.has_key?(model.leased, sid) -> {:stall_taken, model}
          Map.has_key?(model.held, sid) -> {:slot_unavailable, model}
          true -> {:accepted, put_in(model.leased[sid], :npc)}
        end
    end
  end

  defp drop_allocation(model, sid, device),
    do: %{model | held: Map.delete(model.held, sid), queue: List.keydelete(model.queue, device, 0)}

  defp has_allocation?(model, device),
    do: device in Map.values(model.leased) or Enum.any?(model.held, fn {_, {owner, _}} -> owner == device end)

  defp allocate_queued(model, layout) do
    Enum.reduce(model.queue, model, fn {device, tiers}, current ->
      compatible = Enum.find(free_slots(current, layout), &(layout[&1] in tiers))

      if compatible && not has_allocation?(current, device),
        do: put_in(current.held[compatible], {device, current.now + 600_000}),
        else: current
    end)
  end

  defp run_allocation_step(rt, {:advance, _}, _, now, :accepted), do: advance(rt, now)

  defp run_allocation_step(rt, action, id, _, outcome) do
    restaurant = fn sid -> %{stall_id: sid, restaurant_id: id, name: "Kitchen", cuisine: "levantine"} end

    {device, command} =
      case action do
        {:reserve, device, sid} -> {device, {:reserve_stall, %{stall_id: sid}}}
        {:confirm, device, sid} -> {device, {:create_restaurant, restaurant.(sid)}}
        {:npc, sid} -> {nil, {:create_restaurant, restaurant.(sid)}}
        {:join, device, tiers} -> {device, {:join_waitlist, %{tiers: tiers}}}
        {:cancel, device} -> {device, {:cancel_stall_draft, %{}}}
        {:leave, device} -> {device, {:leave_waitlist, %{}}}
      end

    request = %{command_id: id, command: command}

    envelope =
      if device do
        assert {:ok, envelope} = Management.envelope(rt.control, device, request)
        envelope
      else
        Map.put(request, :actor, {:npc, id})
      end

    {status, receipt, next} = CommandWorkflow.execute(rt, envelope)
    expected = if outcome == :accepted, do: :accepted, else: {:rejected, outcome}

    assert receipt.outcome == expected,
           "expected #{inspect(expected)} for #{inspect(action)}, got #{inspect(receipt.outcome)}"

    assert status == if(outcome == :accepted, do: :accepted, else: :rejected)
    next
  end

  property "allowance traces conserve the daily fund across actors, devices, and retries" do
    grant = 1_200
    fund = 2_401
    catalog = put_in(SliceCatalog.catalog().rules.visitor_fund, fund)
    rt = boot(InMemoryEventStore, InMemoryEventStore.new(), catalog)
    {rt, _} = register(rt, "first", "First")
    {rt, _} = register(rt, "second", "Second")
    {rt, _} = register(rt, "third", "Third")
    rt = client(rt, "first", "code", :issue_recovery_code)
    rt = client(rt, "alternate", "restore", :restore_device, %{recovery_code_id: "R:code"})

    devices = %{"first" => :first, "alternate" => :first, "second" => :second, "third" => :third}
    claim = map({member_of(Map.keys(devices)), integer(0..12)}, fn {device, id} -> {:claim, device, id} end)
    step = one_of([claim, map(member_of([1, 2, 299_999, 300_000, 900_000, 3_600_000]), &{:advance, &1})])
    day_ms = 3_600_000

    check all(
            first <- member_of(["first", "alternate"]),
            skew <- integer(1..2),
            steps <- list_of(step, max_length: 24),
            max_runs: 20
          ) do
      other = if first == "first", do: "alternate", else: "first"

      # Guarantee both rejection reasons, cross-device replay, cross-actor conflict,
      # and attempts on both sides of midnight even if the random tail shrinks away.
      prefix = [
        {:advance, day_ms - skew},
        {:claim, first, 0},
        {:claim, other, 0},
        {:claim, other, 1},
        {:claim, "second", 0},
        {:claim, "second", 2},
        {:claim, "third", 3},
        {:advance, skew},
        {:claim, "third", 3},
        {:claim, "third", 4}
      ]

      model = %{
        now: 0,
        remaining: fund,
        issued: MapSet.new(),
        receipts: %{},
        balances: %{first: 0, second: 0, third: 0}
      }

      {last, _} =
        Enum.reduce(prefix ++ steps, {rt, model}, fn action, {current, expected} ->
          {next, expected} =
            case action do
              {:advance, delta} ->
                now = expected.now + delta
                reset? = div(now, day_ms) > div(expected.now, day_ms)
                expected = %{expected | now: now, remaining: if(reset?, do: fund, else: expected.remaining)}
                {advance(current, now), expected}

              {:claim, device, id} ->
                actor = Map.fetch!(devices, device)
                request = %{command_id: "allowance:#{id}", command: {:request_allowance, %{}}}
                assert {:ok, envelope} = Management.envelope(current.control, device, request)

                case Map.fetch(expected.receipts, id) do
                  {:ok, {^actor, receipt}} ->
                    assert {:replayed, ^receipt, ^current} = CommandWorkflow.execute(current, envelope)
                    {current, expected}

                  {:ok, {_other_actor, _receipt}} ->
                    assert {:error, :command_id_conflict, ^current} = CommandWorkflow.execute(current, envelope)
                    {current, expected}

                  :error ->
                    key = {actor, div(expected.now, day_ms)}

                    {outcome, expected} =
                      cond do
                        MapSet.member?(expected.issued, key) ->
                          {{:rejected, :allowance_already_claimed}, expected}

                        expected.remaining < grant ->
                          {{:rejected, :visitor_fund_exhausted}, expected}

                        true ->
                          {:accepted,
                           %{
                             expected
                             | remaining: expected.remaining - grant,
                               issued: MapSet.put(expected.issued, key),
                               balances: Map.update!(expected.balances, actor, &(&1 + grant))
                           }}
                      end

                    status = if outcome == :accepted, do: :accepted, else: :rejected
                    event_count = if outcome == :accepted, do: 2, else: 0

                    assert {^status, %{outcome: ^outcome, event_count: ^event_count} = receipt, next} =
                             CommandWorkflow.execute(current, envelope)

                    {next, put_in(expected.receipts[id], {actor, receipt})}
                end
            end

          assert next.state.visitor_fund == expected.remaining

          for {device, actor} <- devices do
            balance = Integer.to_string(expected.balances[actor])
            claimed = MapSet.member?(expected.issued, {actor, div(expected.now, day_ms)})

            assert {:ok, %{profile: %{balance: ^balance, allowance_claimed: ^claimed}}} =
                     Management.view(next, device)
          end

          {next, expected}
        end)

      assert {:ok, replayed} = CommandWorkflow.open(InMemoryEventStore, last.store)
      assert {replayed.position, replayed.state, replayed.control} == {last.position, last.state, last.control}
    end
  end

  test "public dietary choices reflect the enabled profiles in the hall's pinned catalog" do
    catalog = SliceCatalog.catalog(enable: ~w(unrestricted vegetarian))
    rt = boot(InMemoryEventStore, InMemoryEventStore.new(), catalog)

    assert {:ok, %{hall: %{dietary_profiles: ["unrestricted", "vegetarian"]}, profile: nil}} =
             Management.view(rt, nil)

    assert {:error, :profile_not_enabled} =
             Management.quote(rt, nil, %{stall_id: "s001", main: "chole_masala", profile_id: "keto_style"})
  end

  test "a managed NPC opening refusal commits and replays from PostgreSQL" do
    rt = boot(PostgresEventStore, FeudHall.PostgresCase.fresh_store())
    actor = {:npc, "budget"}

    rt =
      run(rt, "npc:budget:create", actor, :create_restaurant, %{
        restaurant_id: "npc-budget",
        stall_id: "s001",
        name: "NPC budget",
        cuisine: "sichuan"
      })

    slot = 12 * Clock.hour()
    rt = advance(rt, Clock.service_ms(slot))

    planned =
      run(rt, "npc:budget:#{slot}", actor, :npc_plan, %{
        operator: "budget",
        slot: slot,
        actions: [{:open_stall, %{stall_id: "s001"}}],
        rng: 5
      })

    assert {:ok,
            [
              %{
                events: [
                  %{type: :npc_planned, outcomes: [%{action: :open_stall, result: :rejected, reason: :staff_off_duty}]}
                ]
              }
            ]} =
             PostgresEventStore.read_from(planned.store, rt.position)

    assert planned.state.stalls["s001"].mode == :closed
    assert {:ok, restored} = CommandWorkflow.open(PostgresEventStore, planned.store)
    assert restored.state == planned.state
  end

  test "a managed NPC can move its existing starter shift and resume service in one plan" do
    rt = boot(PostgresEventStore, FeudHall.PostgresCase.fresh_store())
    actor = {:npc, "mainstream"}

    rt =
      run(rt, "npc:mainstream:create", actor, :create_restaurant, %{
        restaurant_id: "npc-mainstream",
        stall_id: "s041",
        name: "NPC mainstream",
        cuisine: "mughlai_punjabi"
      })

    rt = run(rt, "npc:mainstream:open", actor, :open_stall, %{stall_id: "s041"})
    slot = 12 * Clock.hour()
    rt = advance(rt, Clock.service_ms(slot))
    assert rt.state.stalls["s041"].mode == :closed

    lease = rt.state.management.leases["s041"]
    assert %{start_hour: 0, end_hour: 12, opening_requested: true} = lease
    own = Map.put(rt.state.restaurants["npc-mainstream"], :lease, lease)
    profile = Enum.find(rt.state.catalog.npc_profiles, &(&1.id == "mainstream"))
    {actions, rng} = Planner.plan(PublicView.build(rt.state), own, profile, rt.state.catalog, 5)

    planned =
      run(rt, "npc:mainstream:#{slot}", actor, :npc_plan, %{
        operator: "mainstream",
        slot: slot,
        actions: actions,
        rng: rng
      })

    assert {:ok, [%{events: events}]} = PostgresEventStore.read_from(planned.store, rt.position)
    assert Enum.count(events, &match?(%{type: :stall_opened, stall_id: "s041"}, &1)) == 1
    assert %{start_hour: 12, end_hour: 0} = planned.state.management.leases["s041"]
    assert planned.state.stalls["s041"].mode == :open
  end

  test "invitation, same-principal promotion, device recovery, and PostgreSQL replay" do
    rt = boot(PostgresEventStore, FeudHall.PostgresCase.fresh_store())
    {rt, root} = register(rt, "root-device", "Root")
    rt = run(rt, "seed", {:system, :admin}, :seed_owner, %{principal: root, reviewer?: true})
    {rt, guest} = register(rt, "guest-device", "Guest")
    rt = client(rt, "root-device", "invite", :issue_invitation)
    rt = client(rt, "guest-device", "redeem", :redeem_invitation, %{invitation_id: "I:invite"})
    rt = client(rt, "guest-device", "recover", :issue_recovery_code)
    rt = client(rt, "replacement", "restore", :restore_device, %{recovery_code_id: "R:recover"})
    rt = client(rt, "guest-device", "logout", :revoke_device)

    assert {:ok, %{profile: nil}} = Management.view(rt, "guest-device")

    assert {:ok, %{profile: %{account: %{id: ^guest, parent: ^root, owner?: true, reviewer?: false}}}} =
             Management.view(rt, "replacement")

    assert {:ok, restored} = CommandWorkflow.open(PostgresEventStore, rt.store)
    assert restored.control == rt.control
  end

  test "cleanup gates a queued opening and releases unconfirmed stall drafts" do
    rt = boot(InMemoryEventStore, InMemoryEventStore.new())
    {rt, owner} = register(rt, "owner-device", "Owner")
    {rt, other} = register(rt, "other-device", "Other")
    rt = run(rt, "seed", {:system, :admin}, :seed_owner, %{principal: owner, reviewer?: true})
    rt = run(rt, "seed-other", {:system, :admin}, :seed_owner, %{principal: other, reviewer?: false})
    rt = client(rt, "owner-device", "reserve", :reserve_stall, %{stall_id: "s001"})
    rt = client(rt, "other-device", "reserve-other", :reserve_stall, %{stall_id: "s002"})

    rt =
      client(rt, "owner-device", "lease", :create_restaurant, %{
        restaurant_id: "r1",
        stall_id: "s001",
        name: "Kitchen",
        cuisine: "sichuan"
      })

    rt = client(rt, "owner-device", "staff", :set_staff_schedule, %{stall_id: "s001", start_hour: 5, end_hour: 17})

    rt =
      client(rt, "owner-device", "unattended", :set_unattended_policy, %{stall_id: "s001", enabled: true, cash_floor: 0})

    rt = advance(rt, Clock.service_ms(Clock.cleaning_start_of(0)))
    assert rt.state.access == :cleaning
    assert [%{day: 0}] = rt.state.management.reports["r1"]
    rt = client(rt, "owner-device", "queue-open", :open_stall, %{stall_id: "s001"})
    assert rt.state.stalls["s001"].mode == :closed
    rt = advance(rt, Clock.service_ms(Clock.cleaning_end_of(0)))
    assert rt.state.stalls["s001"].mode == :open
    assert rt.state.management.drafts == %{}
    refute Map.has_key?(rt.state.owners, {:principal, other})
  end

  test "fatigue changes new kitchen work and protective breaks stop and resume staffing" do
    rt = boot(InMemoryEventStore, InMemoryEventStore.new())
    {rt, owner} = register(rt, "owner-device", "Owner")
    rt = run(rt, "seed", {:system, :admin}, :seed_owner, %{principal: owner, reviewer?: true})
    rt = client(rt, "owner-device", "reserve", :reserve_stall, %{stall_id: "s001"})

    rt =
      client(rt, "owner-device", "lease", :create_restaurant, %{
        restaurant_id: "r1",
        stall_id: "s001",
        name: "Kitchen",
        cuisine: "sichuan"
      })

    rt = client(rt, "owner-device", "staff", :set_staff_schedule, %{stall_id: "s001", start_hour: 5, end_hour: 17})

    rt =
      client(rt, "owner-device", "unattended", :set_unattended_policy, %{stall_id: "s001", enabled: true, cash_floor: 0})

    rt = advance(rt, Clock.service_ms(Clock.cleaning_start_of(0)))
    rt = client(rt, "owner-device", "queue-open", :open_stall, %{stall_id: "s001"})

    rt = advance(rt, Clock.service_ms(13 * Clock.hour()))
    course = %{prep_ms: 1_000, finish_ms: 1_000}
    assert HallManagement.adapt_course(rt.state, "s001", course) == %{prep_ms: 1_100, finish_ms: 1_100}
    rt = advance(rt, Clock.service_ms(15 * Clock.hour()))
    assert rt.state.stalls["s001"].mode == :closed
    refute HallManagement.stage_available?(rt.state, "s001", :prep_cook)

    rt = advance(rt, Clock.service_ms(16 * Clock.hour()))
    assert rt.state.stalls["s001"].mode == :open
    assert HallManagement.adapt_course(rt.state, "s001", course) == course
  end

  test "standby alone does not create licensing eligibility" do
    start = 0
    stop = Clock.service_duration(60_000)
    shift = %{at: start, expires_at: stop, rate: 650, tasks: 0}
    state = %{now: stop, management: %{shifts: %{"H:standby" => shift}}}
    event = HallManagement.end_shift(state, "H:standby", :scheduled_end)
    assert event.amount > 0
    assert event.qualified == false
    assert HallManagement.shift_proof(state, event) == nil
  end

  property "selection retries around the deadline settle one shift through cleaning and replay" do
    rt = boot(InMemoryEventStore, InMemoryEventStore.new())
    {rt, helper} = register(rt, "helper-device", "Helper")
    npc = {:npc, "budget"}

    rt =
      run(rt, "npc:budget:create", npc, :create_restaurant, %{
        restaurant_id: "npc-budget",
        stall_id: "s001",
        name: "Counter",
        cuisine: "levantine"
      })

    rt = run(rt, "starter-stock", npc, :request_starter_stock, %{restaurant_id: "npc-budget", budget: 500_000})
    cleaning = Clock.cleaning_start_of(0)
    rt = advance(rt, Clock.service_ms(cleaning) - 25_000)
    rt = run(rt, "npc:budget:open", npc, :open_stall, %{stall_id: "s001"})
    assert {:ok, offer} = HallManagement.shift_offer(rt.state, "s001", helper)
    assert offer.expires_at == cleaning

    rt =
      client(
        rt,
        "helper-device",
        "shift",
        :accept_helper_shift,
        Map.take(offer, [:stall_id, :rate, :quoted_at, :expires_at])
      )

    recipe = rt.state.catalog.recipes["falafel_wrap"]

    rt =
      run(rt, "dine", {:system, :demand}, :admit_visit, %{
        source: :simulated,
        diner_id: "d",
        stall_id: "s001",
        main: recipe.id,
        profile_id: "unrestricted",
        budget: 2_000
      })

    ready = rt.state.now + recipe.prep_ms + recipe.finish_ms
    rt = advance(rt, div(ready + Clock.ratio() - 1, Clock.ratio()))
    rt = client(rt, "helper-device", "heartbeat-ready", :report_helper_presence, %{shift_id: "H:shift"})
    selection = rt.state.management.selections["s001"]
    assert %{shift_id: "H:shift", deadline: deadline} = selection
    assert deadline < cleaning
    assert rem(deadline, Clock.ratio()) == 0

    {:ok, choose} =
      Management.envelope(rt.control, "helper-device", %{
        command_id: "choose",
        command:
          {:select_handover,
           %{shift_id: "H:shift", selection_id: selection.id, item_id: "T:dine", recipes: [recipe.id]}}
      })

    check all(skew <- integer(1..2), retries <- integer(1..3), split? <- boolean(), max_runs: 8) do
      for offset <- [-skew, 0, skew] do
        instant = Clock.service_ms(deadline) + offset
        before_choice = advance(rt, instant)
        {status, receipt, chosen} = CommandWorkflow.execute(before_choice, choose)
        on_time? = offset < 0
        assert status == if(on_time?, do: :accepted, else: :rejected)

        for _ <- 1..retries do
          assert {:replayed, ^receipt, ^chosen} = CommandWorkflow.execute(chosen, choose)
        end

        before_cleaning = if split?, do: advance(chosen, Clock.service_ms(cleaning) - 1), else: chosen
        finished = advance(before_cleaning, Clock.service_ms(cleaning))
        assert {:replayed, ^receipt, ^finished} = CommandWorkflow.execute(finished, choose)

        assert {:ok, batches} = InMemoryEventStore.read_from(finished.store, rt.position)
        events = Enum.flat_map(batches, & &1.events)
        assert Enum.count(events, &(&1.type == :helper_task_completed)) == if(on_time?, do: 1, else: 0)
        assert Enum.count(events, &(&1.type == :tray_served)) == 1
        assert [%{amount: amount}] = Enum.filter(events, &(&1.type == :helper_shift_ended))
        stop = if on_time?, do: cleaning, else: deadline
        assert amount == div((stop - offer.quoted_at) * offer.rate, Clock.hour())
        assert %{amount: ^amount, reserved: 0} = finished.state.wallets[helper].slices["W:H:shift"]
        assert finished.state.management.shift_by_principal == %{}
        assert {:ok, replayed} = CommandWorkflow.open(InMemoryEventStore, finished.store)
        assert replayed.state == finished.state
        assert replayed.control == finished.control
      end
    end
  end

  for adapter <- [:memory, :postgres] do
    @adapter adapter
    test "#{adapter}: a helper task pays once and earns the proof used for license review" do
      {store_mod, store} =
        if @adapter == :postgres,
          do: {PostgresEventStore, FeudHall.PostgresCase.fresh_store()},
          else: {InMemoryEventStore, InMemoryEventStore.new()}

      rt = boot(store_mod, store)
      {rt, owner} = register(rt, "owner-device", "Owner")
      {rt, guest} = register(rt, "helper-device", "Helper")
      rt = run(rt, "seed", {:system, :admin}, :seed_owner, %{principal: owner, reviewer?: true})
      rt = client(rt, "owner-device", "reserve", :reserve_stall, %{stall_id: "s001"})
      assert rt.state.restaurants == %{}

      rt =
        client(rt, "owner-device", "lease", :create_restaurant, %{
          restaurant_id: "r1",
          stall_id: "s001",
          name: "Kitchen",
          cuisine: "mughlai_punjabi"
        })

      recipe = rt.state.catalog.recipes["chole_with_rice"]

      assert {:ok, %{profile: %{restaurant: %{starter_stock: %{budget: budget, items: [_ | _]}}}}} =
               Management.view(rt, "owner-device")

      rt =
        client(rt, "owner-device", "starter-stock", :request_starter_stock, %{
          restaurant_id: "r1",
          budget: String.to_integer(budget)
        })

      rt = advance(rt, 10_000)

      rt =
        client(rt, "owner-device", "policy", :set_unattended_policy, %{stall_id: "s001", enabled: true, cash_floor: 0})

      rt = client(rt, "owner-device", "open", :open_stall, %{stall_id: "s001"})
      rt = client(rt, "owner-device", "helpers", :set_helper_offers, %{stall_id: "s001", enabled: true})
      assert {:ok, offer} = HallManagement.shift_offer(rt.state, "s001", guest)

      {:ok, shortened} =
        Management.envelope(rt.control, "helper-device", %{
          command_id: "short-shift",
          command:
            {:accept_helper_shift,
             %{stall_id: offer.stall_id, rate: offer.rate, quoted_at: offer.quoted_at, expires_at: offer.quoted_at + 24}}
        })

      assert {:rejected, %{outcome: {:rejected, :stale_shift_offer}}, rt} =
               CommandWorkflow.execute(rt, shortened)

      assert rt.state.management.shift_by_principal == %{}

      rt =
        client(
          rt,
          "helper-device",
          "shift",
          :accept_helper_shift,
          Map.take(offer, [:stall_id, :rate, :expires_at, :quoted_at])
        )

      rt =
        run(rt, "dine", {:system, :demand}, :admit_visit, %{
          source: :simulated,
          diner_id: "d",
          stall_id: "s001",
          main: recipe.id,
          profile_id: "unrestricted",
          budget: 2_000
        })

      prep = rt.state.now + recipe.prep_ms + recipe.finish_ms
      rt = advance(rt, div(prep + 23, 24))
      selection = rt.state.management.selections["s001"]
      assert selection.shift_id == "H:shift"
      item = %{id: "T:dine", recipes: [recipe.id]}

      assert {:ok, %{profile: %{work: %{active: %{selection: %{items: [^item], choice: nil}, handover: nil}}}}} =
               Management.view(rt, "helper-device")

      rt =
        client(rt, "helper-device", "select", :select_handover, %{
          shift_id: "H:shift",
          selection_id: selection.id,
          item_id: "T:dine",
          recipes: [recipe.id]
        })

      rt = client(rt, "helper-device", "heartbeat-at-selection", :report_helper_presence, %{shift_id: "H:shift"})

      assert {:ok, %{profile: %{work: %{active: %{selection: %{choice: ^item}, handover: nil, tasks: 0}}}}} =
               Management.view(rt, "helper-device")

      rt = advance(rt, div(selection.deadline + Clock.ratio() - 1, Clock.ratio()))

      assert {:ok, %{profile: %{work: %{active: %{selection: nil, handover: handover, tasks: 0}}}}} =
               Management.view(rt, "helper-device")

      assert Map.drop(handover, [:done_at]) == item
      assert handover.done_at > rt.state.now
      assert {:ok, %{profile: %{work: %{active: nil}}}} = Management.view(rt, "owner-device")
      target = Clock.service_ms(offer.expires_at)

      rt =
        Stream.iterate(Clock.service_ms(rt.state.now) + 10_000, &(&1 + 10_000))
        |> Enum.take_while(&(&1 < target))
        |> Enum.reduce(rt, fn instant, current ->
          current
          |> advance(instant)
          |> client("helper-device", "heartbeat-#{instant}", :report_helper_presence, %{shift_id: "H:shift"})
        end)

      rt = advance(rt, target)

      assert %{status: :ended, tasks: 1, qualified: true, amount: amount} = rt.state.management.shifts["H:shift"]
      assert amount > 0
      assert %{amount: ^amount} = rt.state.wallets[guest].slices["W:H:shift"]
      assert Identity.principal(Identity.get(rt.control), guest).proof.tasks == 1
      rt = client(rt, "helper-device", "app", :apply_for_license, %{motivation: nil})
      assert {:ok, %{profile: %{reviewer_queue: [%{application_id: "L:app"}]}}} = Management.view(rt, "owner-device")

      rt = run(rt, "review-revoked", {:system, :admin}, :set_license_reviewer, %{principal: owner, enabled: false})
      assert {:ok, %{profile: %{reviewer_queue: []}}} = Management.view(rt, "owner-device")

      assert {:rejected, %{outcome: {:rejected, :review_unavailable}}, rt} =
               CommandWorkflow.execute(rt, %{
                 command_id: "revoked-review",
                 actor: {:principal, owner},
                 command: {:review_license_application, %{application_id: "L:app", decision: :approved, reason: nil}}
               })

      assert Identity.get(rt.control).applications["L:app"].status == :pending
      rt = run(rt, "review-restored", {:system, :admin}, :set_license_reviewer, %{principal: owner, enabled: true})

      # Approval can arrive during a subsequent shift: revoke work in the same batch.
      assert {:ok, next_offer} = HallManagement.shift_offer(rt.state, "s001", guest)

      rt =
        client(
          rt,
          "helper-device",
          "next-shift",
          :accept_helper_shift,
          Map.take(next_offer, [:stall_id, :rate, :expires_at, :quoted_at])
        )

      rt =
        client(rt, "owner-device", "approve", :review_license_application, %{
          application_id: "L:app",
          decision: :approved,
          reason: nil
        })

      assert Identity.principal(Identity.get(rt.control), guest).parent == owner
      assert rt.state.management.shifts["H:next-shift"].reason == :owner_ineligible
      assert rt.state.management.shift_by_principal == %{}
      assert {:ok, %{profile: %{work: %{active: nil, offers: []}}}} = Management.view(rt, "helper-device")
      assert rt.state.wallets[guest].slices["W:H:shift"].amount == amount
      assert {:ok, replayed} = CommandWorkflow.open(store_mod, rt.store)
      assert replayed.state == rt.state
      assert replayed.control == rt.control
    end
  end
end
