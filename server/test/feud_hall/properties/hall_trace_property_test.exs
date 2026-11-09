defmodule FeudHall.Properties.HallTraceTest do
  @moduledoc """
  Model-based property: random command traces against the pure hall.

  Budgets are explicit (runs, trace length, advance sizes). Symbolic actions
  pick concrete targets from current state by index, so shrinking removes
  actions without leaving dangling IDs. After every accepted command the
  independent oracle must report no violations; at the end, genesis replay,
  snapshot-plus-tail replay, and a JSON codec round trip must reproduce the
  live state exactly, and splitting the final clock advance must not change
  the outcome. Aggregate progress counters guard against vacuous passes.
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  import FeudHall.Fixtures, only: [stocked_world: 1, run!: 4, ctx: 2]

  alias FeudHall.Domain.{Clock, Dietary, Hall, Offers}
  alias FeudHall.Domain.Content.SliceCatalog
  alias FeudHall.Infrastructure.{EventCodec, Snapshot}
  alias FeudHall.Oracle

  @runs 100
  @max_actions 70
  @mains ~w(bean_tacos chicken_tacos vegetable_quesadilla)
  @profiles ~w(unrestricted vegetarian vegan carb_conscious)
  @guests ~w(gina hiro ivy)
  @recipes ~w(bean_tacos chicken_tacos vegetable_quesadilla arroz_con_leche horchata)

  # Short shelf lives so spoilage and claim replacement occur within a trace.
  defp catalog do
    SliceCatalog.catalog()
    |> put_in([:products, "cilantro", :shelf_life_ms], 3 * Clock.hour())
    |> put_in([:products, "milk_whole", :shelf_life_ms], 5 * Clock.hour())
    |> put_in([:products, "salsa_roja", :shelf_life_ms], 9 * Clock.hour())
  end

  defp action do
    frequency([
      {4, tuple({constant(:advance), integer(1..60_000)})},
      {1, tuple({constant(:advance_to), member_of([:cleaning_start, :cleaning_end]), integer(-2..2)})},
      {4, tuple({constant(:purchase), integer(0..24), integer(50..600)})},
      {1,
       tuple(
         {constant(:policy), integer(0..4), integer(0..4),
          member_of([:primary_only, :prefer_primary, :prefer_substitute])}
       )},
      {1, tuple({constant(:price), integer(0..4), integer(100..2_000)})},
      {4,
       tuple({constant(:sim_visit), integer(0..2), member_of([nil, "horchata"]), integer(0..3), integer(500..4_000)})},
      {3,
       tuple(
         {constant(:guest_visit), integer(0..2), integer(0..2), member_of([nil, "horchata"]), integer(0..3), boolean()}
       )},
      {2, tuple({constant(:grant), integer(0..2), integer(100..2_500)})},
      {6, tuple({constant(:kitchen), integer(0..1_000)})},
      {2, constant({:kitchen_all})},
      {5, tuple({constant(:cycle), integer(4_000..20_000), boolean()})},
      {2, tuple({constant(:cancel), integer(0..1_000)})},
      {3, tuple({constant(:dessert), integer(0..1_000), member_of([:accept, :decline, :cancel, :stale])})},
      {1, tuple({constant(:stall), member_of([:open_stall, :open_stall, :close_stall])})},
      {1, tuple({constant(:intrude), integer(0..3)})}
    ])
  end

  property "random traces keep every invariant and replay exactly" do
    Process.put(:progress, %{
      served_trays: 0,
      desserts_served: 0,
      cleanings: 0,
      cancellations: 0,
      spoiled: 0,
      stale_rejected: 0
    })

    # A large initial size yields long traces while still letting shrinking
    # reduce a counterexample to its minimal prefix.
    check all(
            actions <- list_of(action(), max_length: @max_actions),
            cut <- integer(0..1_000),
            split <- integer(1..59_999),
            max_runs: @runs,
            initial_size: 40
          ) do
      world = stocked_world(catalog: catalog())
      {batches, n} = initial_batches(world)
      {state, batches, _n} = Enum.reduce(actions, {elem(world, 0), batches, n}, &step/2)
      events = Enum.flat_map(batches, & &1)

      # Genesis replay.
      assert Hall.replay(events) == state

      # Snapshot at a complete batch boundary plus the remaining tail.
      k = rem(cut, length(batches) + 1)
      {prefix, tail} = Enum.split(batches, k)
      snapshot = Snapshot.take(Hall.replay(Enum.concat(prefix)), k)
      positioned = tail |> Enum.with_index(k + 1) |> Enum.map(fn {evs, pos} -> %{position: pos, events: evs} end)
      assert {:ok, ^state} = Snapshot.restore(snapshot, positioned)

      # Serialized history decodes and replays to the same state.
      decoded =
        Enum.map(events, fn e ->
          {:ok, d} = e |> EventCodec.encode!() |> EventCodec.decode()
          d
        end)

      assert Hall.replay(decoded) == state

      # Partitioning one declared available interval preserves the outcome.
      base = Clock.service_ms(state.now) + 1
      target = base + 60_000
      {:ok, one} = Hall.decide(state, {:advance_clock, %{to_service_ms: target}}, ctx({:system, :scheduler}, "one"))

      {:ok, first} =
        Hall.decide(state, {:advance_clock, %{to_service_ms: base + split}}, ctx({:system, :scheduler}, "a"))

      mid = Hall.replay(first, state)
      {:ok, second} = Hall.decide(mid, {:advance_clock, %{to_service_ms: target}}, ctx({:system, :scheduler}, "b"))
      whole = Hall.replay(one, state)
      assert Hall.replay(second, mid) == whole
      Oracle.assert_settled!(whole, events ++ one)

      record_progress(events)
    end

    progress = Process.get(:progress)
    # Non-vacuity: the generated traces must exercise the lifecycles we claim.
    for {key, min} <- [
          served_trays: 25,
          desserts_served: 3,
          cleanings: 10,
          cancellations: 10,
          spoiled: 10,
          stale_rejected: 10
        ] do
      assert progress[key] >= min, "too little #{key} across runs: #{inspect(progress)}"
    end
  end

  defp initial_batches({_state, log}), do: {[log], 1}

  # -- interpreter ------------------------------------------------------------------

  defp step(action, {state, batches, n}) do
    id = "c#{n}"

    case command(state, action, id) do
      nil ->
        {state, batches, n + 1}

      {:expect_reject, cmd, actor, reason} ->
        assert {:error, ^reason} = Hall.decide(state, cmd, ctx(actor, id))
        bump(:stale_rejected)
        {state, batches, n + 1}

      {:sequence, parts} ->
        Enum.reduce(parts, {state, batches, n + 1}, fn part, {st, bs, m} ->
          moves =
            case part do
              :kitchen ->
                kitchen_moves(st)

              :desserts ->
                dessert_answers(st)

              {:wait, ms} ->
                [{{:advance_clock, %{to_service_ms: Clock.service_ms(st.now) + ms}}, {:system, :scheduler}}]
            end

          Enum.reduce(moves, {st, bs, m}, fn {cmd, actor}, {st2, bs2, m2} ->
            apply_command(st2, bs2, m2 + 1, cmd, actor, "#{id}.#{m2}")
          end)
        end)

      list when is_list(list) ->
        Enum.reduce(list, {state, batches, n + 1}, fn {cmd, actor}, {st, bs, m} ->
          apply_command(st, bs, m, cmd, actor, "#{id}.#{m}")
        end)

      {cmd, actor} ->
        apply_command(state, batches, n + 1, cmd, actor, id)
    end
  end

  defp apply_command(state, batches, n, cmd, actor, id) do
    case Hall.decide(state, cmd, ctx(actor, id)) do
      {:ok, events} ->
        state = Hall.replay(events, state)
        batches = batches ++ [events]

        case Oracle.violations(state, Enum.concat(batches)) do
          [] -> {state, batches, n}
          problems -> flunk("after #{inspect(cmd)}: #{inspect(problems)}")
        end

      {:error, _reason} ->
        {state, batches, n}
    end
  end

  defp command(state, {:advance, ms}, _id),
    do: {{:advance_clock, %{to_service_ms: Clock.service_ms(state.now) + ms}}, {:system, :scheduler}}

  defp command(state, {:advance_to, which, offset}, _id) do
    boundary =
      if which == :cleaning_start, do: Clock.next_cleaning_start(state.now), else: Clock.next_cleaning_end(state.now)

    target = max(Clock.service_ms(boundary) + offset, Clock.service_ms(state.now))
    {{:advance_clock, %{to_service_ms: target}}, {:system, :scheduler}}
  end

  defp command(state, {:purchase, idx, qty}, _id) do
    product = state.catalog.products |> Map.keys() |> Enum.sort() |> Enum.at(idx)
    scale = if state.catalog.products[product].unit == :each, do: max(div(qty, 20), 1), else: qty

    {{:purchase_stock, %{restaurant_id: "r1", product: product, qty: scale, max_price_per_kunit: 1_000_000_000}},
     {:principal, "alice"}}
  end

  defp command(state, {:policy, r, l, policy}, _id) do
    recipe = state.catalog.recipes[Enum.at(@recipes, r)]
    line = Enum.at(recipe.lines, rem(l, length(recipe.lines)))

    {{:set_substitution_policy, %{restaurant_id: "r1", recipe_id: recipe.id, line_id: line.line_id, policy: policy}},
     {:principal, "alice"}}
  end

  defp command(_state, {:price, r, price}, _id),
    do:
      {{:set_menu_price, %{restaurant_id: "r1", recipe_id: Enum.at(@recipes, r), price: price}}, {:principal, "alice"}}

  defp command(_state, {:sim_visit, m, drink, p, budget}, id) do
    {{:admit_visit,
      %{
        source: :simulated,
        diner_id: id,
        budget: budget,
        stall_id: "s1",
        main: Enum.at(@mains, m),
        drink: drink,
        profile_id: Enum.at(@profiles, p)
      }}, {:system, :demand}}
  end

  defp command(state, {:guest_visit, g, m, drink, p, stale}, _id) do
    guest = Enum.at(@guests, g)
    {:ok, req} = Dietary.requirement(state.catalog, Enum.at(@profiles, p))
    payload = %{source: :guest, stall_id: "s1", main: Enum.at(@mains, m), drink: drink, profile_id: req.profile_id}

    case Offers.quote_tray(state, "s1", payload.main, drink, %{requirement: req, carbs_reserved: 0, carbs_served: 0}) do
      {:ok, quote} ->
        terms = Offers.terms(quote)

        if stale do
          [first | rest] = terms.components
          stale_terms = %{terms | components: [%{first | price: first.price + 1} | rest]}
          # One active visit per principal is checked before confirmed terms.
          reason = if Map.has_key?(state.active_visits, guest), do: :visit_already_active, else: :stale_terms
          {:expect_reject, {:admit_visit, Map.put(payload, :confirmed, stale_terms)}, {:principal, guest}, reason}
        else
          {{:admit_visit, Map.put(payload, :confirmed, terms)}, {:principal, guest}}
        end

      {:error, _} ->
        nil
    end
  end

  defp command(_state, {:grant, g, amount}, _id),
    do: {{:grant_allowance, %{principal: Enum.at(@guests, g), amount: amount}}, {:system, :visitor_fund}}

  defp command(state, {:kitchen, k}, _id) do
    case kitchen_moves(state) do
      [] -> nil
      moves -> Enum.at(moves, rem(k, length(moves)))
    end
  end

  defp command(state, {:kitchen_all}, _id), do: kitchen_moves(state)

  # A service cycle: start waiting work, let it cook, complete and serve it.
  # Later moves are planned against the state reached after earlier ones.
  defp command(_state, {:cycle, ms, desserts}, _id) do
    answer = if desserts, do: [:desserts], else: []
    {:sequence, [:kitchen, {:wait, ms}, :kitchen, :kitchen] ++ answer ++ [:kitchen]}
  end

  defp command(state, {:cancel, k}, _id) do
    trays = state.trays |> Map.values() |> Enum.filter(&(&1.status == :accepted)) |> Enum.sort_by(& &1.id)

    case trays do
      [] ->
        nil

      _ ->
        tray = Enum.at(trays, rem(k, length(trays)))
        {{:cancel_tray, %{tray_id: tray.id}}, {:principal, state.visits[tray.visit].principal}}
    end
  end

  defp command(state, {:dessert, k, op}, _id) do
    visits =
      state.visits
      |> Map.values()
      |> Enum.filter(&(&1.status == :active and &1.dessert in [:offered, :accepted]))
      |> Enum.sort_by(& &1.id)

    case visits do
      [] -> nil
      _ -> dessert_command(state, Enum.at(visits, rem(k, length(visits))), op)
    end
  end

  defp command(_state, {:stall, cmd}, _id), do: {{cmd, %{stall_id: "s1"}}, {:principal, "alice"}}

  # An unrelated principal attempting owner, kitchen, or wallet operations.
  defp command(_state, {:intrude, which}, _id) do
    cmd =
      case which do
        0 -> {:purchase_stock, %{restaurant_id: "r1", product: "sugar", qty: 1, max_price_per_kunit: 1_000_000}}
        1 -> {:set_menu_price, %{restaurant_id: "r1", recipe_id: "bean_tacos", price: 1}}
        2 -> {:close_stall, %{stall_id: "s1"}}
        3 -> {:grant_allowance, %{principal: "mallory", amount: 100}}
      end

    {:expect_reject, cmd, {:principal, "mallory"}, if(which == 3, do: :unauthorized_or_malformed, else: :forbidden)}
  end

  defp dessert_command(state, %{source: source} = visit, op) do
    actor = if source == :guest, do: {:principal, visit.principal}, else: {:system, :demand}

    case op do
      :decline ->
        {{:decline_dessert, %{visit_id: visit.id}}, actor}

      :cancel when source == :guest ->
        {{:cancel_dessert, %{visit_id: visit.id}}, actor}

      :cancel ->
        nil

      _accept_or_stale when source == :simulated ->
        {{:accept_dessert, %{visit_id: visit.id}}, actor}

      accept_or_stale ->
        case Offers.quote_dessert(state, visit) do
          {:ok, quote} ->
            terms = Offers.terms(quote)

            if accept_or_stale == :stale do
              {:expect_reject,
               {:accept_dessert, %{visit_id: visit.id, confirmed: %{terms | deadline: terms.deadline + 1}}}, actor,
               if(visit.dessert == :offered, do: :stale_terms, else: :no_dessert_offer)}
            else
              {{:accept_dessert, %{visit_id: visit.id, confirmed: terms}}, actor}
            end

          {:error, _} ->
            nil
        end
    end
  end

  # Accept every open dessert offer that can be confirmed right now.
  defp dessert_answers(state) do
    state.visits
    |> Map.values()
    |> Enum.filter(&(&1.status == :active and &1.dessert == :offered))
    |> Enum.sort_by(& &1.id)
    |> Enum.flat_map(fn visit ->
      case dessert_command(state, visit, :accept) do
        {cmd, actor} -> [{cmd, actor}]
        _ -> []
      end
    end)
  end

  defp kitchen_moves(state) do
    orders = state.orders |> Map.values() |> Enum.sort_by(& &1.id)

    starts = for o <- orders, o.status == :reserved, do: {{:start_preparation, %{order_id: o.id}}, {:system, :kitchen}}

    completes =
      for o <- orders,
          o.status == :preparing,
          state.now >= o.ready_not_before,
          do: {{:complete_preparation, %{order_id: o.id}}, {:system, :kitchen}}

    serves =
      for {_, t} <- Enum.sort(state.trays),
          t.status == :accepted,
          do: {{:serve_tray, %{tray_id: t.id}}, {:system, :kitchen}}

    desserts =
      for o <- orders,
          o.kind == :dessert,
          o.status == :ready,
          do: {{:serve_dessert, %{order_id: o.id}}, {:system, :kitchen}}

    completes ++ serves ++ desserts ++ starts
  end

  defp record_progress(events) do
    count = fn type -> Enum.count(events, &(&1.type == type)) end
    bump(:served_trays, count.(:tray_served))
    bump(:desserts_served, count.(:dessert_served))
    bump(:cleanings, count.(:hall_cleaning_started))
    bump(:cancellations, count.(:tray_cancelled) + count.(:dessert_cancelled))
    bump(:spoiled, count.(:stock_spoiled))
  end

  defp bump(key, by \\ 1), do: Process.put(:progress, Map.update!(Process.get(:progress), key, &(&1 + by)))

  # Silence unused-import warnings for helpers used only in some builds.
  _ = &run!/4
end
