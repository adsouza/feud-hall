defmodule FeudHall.HallTrace do
  @moduledoc """
  Random hall command traces for the model-based properties: the symbolic
  action generator and the pure interpreter that runs a trace against
  `Hall.decide/3`.

  Symbolic actions pick concrete targets from current state by index, so
  shrinking removes actions without leaving dangling IDs. After every accepted
  command the independent oracle must report no violations.

  The hall starts from the `stocked_world` fixture (alice's restaurant `r1`
  at `s001`, stocked and open, with the arrival stream on) plus the catalog's
  NPC restaurants, created as the authority bootstraps them. Besides single
  owner, guest, simulated-diner and clock commands, the vocabulary includes
  market actions (`{:request, idx, qty}`, `{:cancel_request, idx}`), and
  macros that finish lifecycles random steps rarely complete:
  `{:market_clear}` (advance to the next clearing), `{:meal_peak}` (through
  12:00 to 13:00 with a restock and NPC plans), `{:npc_slot}` (to the next
  hour boundary, then each due NPC's plan through `Planner.plan/5`, submitted
  as `{:npc, op}` with ID `npc:<op>:<slot>`), `{:dessert_course, guest}` (a
  guest's whole main-then-dessert visit), `{:cycle, ms, desserts}`, and
  `{:regret, ...}`.

  `run/2` also records every decided command (the `stocked_world` setup, then
  each accepted, rejected, or expected-rejection decision of the trace) as
  `{command, ctx}` in order, with the pure outcome of each in `outcomes`
  (`:accepted` or `{:rejected, reason}`, the shape of a workflow receipt's
  `outcome`), so the same trace can be replayed through the application
  command workflow. `envelopes/1` turns those into workflow envelopes.
  """

  import ExUnit.Assertions
  import StreamData
  import FeudHall.Fixtures, only: [stocked_world_steps: 1, ctx: 2]

  alias FeudHall.Domain.{Clock, Dietary, Hall, Offers, PublicView}
  alias FeudHall.Domain.Content.SliceCatalog
  alias FeudHall.Domain.Npc.Planner
  alias FeudHall.Oracle

  @stall "s001"
  @mains ~w(bean_tacos chicken_tacos vegetable_quesadilla)
  @profiles ~w(unrestricted vegetarian vegan carb_conscious)
  @guests ~w(gina hiro ivy)
  @recipes ~w(bean_tacos chicken_tacos vegetable_quesadilla arroz_con_leche horchata)

  @doc "The trace catalog: short shelf lives so spoilage and claim replacement occur within a trace."
  def catalog do
    SliceCatalog.catalog()
    |> put_in([:products, "cilantro", :shelf_life_ms], 3 * Clock.hour())
    |> put_in([:products, "milk_whole", :shelf_life_ms], 5 * Clock.hour())
    |> put_in([:products, "salsa_roja", :shelf_life_ms], 9 * Clock.hour())
  end

  @doc "The symbolic action generator."
  def action do
    frequency([
      {4, tuple({constant(:advance), integer(1..60_000)})},
      {1, tuple({constant(:advance_to), member_of([:cleaning_start, :cleaning_end]), integer(-2..2)})},
      {4, tuple({constant(:request), integer(0..24), integer(50..600)})},
      {2, tuple({constant(:cancel_request), integer(0..24)})},
      {2, constant({:market_clear})},
      {1, constant({:meal_peak})},
      {2, constant({:npc_slot})},
      {2, tuple({constant(:dessert_course), integer(0..2)})},
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
      {6, tuple({constant(:wait), integer(1_000..20_000)})},
      {5, tuple({constant(:cycle), integer(4_000..20_000), boolean()})},
      {2, tuple({constant(:cancel), integer(0..1_000)})},
      {2, tuple({constant(:regret), integer(0..2), integer(0..2), member_of([nil, "horchata"]), integer(0..3)})},
      {3, tuple({constant(:dessert), integer(0..1_000), member_of([:accept, :decline, :cancel, :stale])})},
      {1, tuple({constant(:stall), member_of([:open_stall, :open_stall, :close_stall])})},
      {1, tuple({constant(:intrude), integer(0..3)})}
    ])
  end

  @doc """
  The closing service both properties append to every generated trace, so each
  run reaches the structural floors of `floors/1`: reopen alice's stall, run
  a lunch peak (restock and clearing fills, stream arrivals admitted and
  leaving, trays served by the automatic kitchen, NPC plans), then one more
  NPC planning slot.
  """
  def closing, do: [{:stall, :open_stall}, {:meal_peak}, {:npc_slot}]

  @doc """
  Structural progress of one run, counted over the trace's events after the
  fixture setup: market clearings with a fill, stream arrivals admitted and
  left, trays served, and NPC plans committed. Each must be at least one.
  """
  def floors(%{batches: [_setup | trace]}) do
    events = Enum.concat(trace)
    arrived = for %{type: :diner_arrived, outcome: outcome} <- events, do: outcome

    %{
      clearings_with_fill: Enum.count(events, &match?(%{type: :market_cleared, fills: [_ | _]}, &1)),
      arrivals_admitted: Enum.count(arrived, &(&1 == :admitted)),
      arrivals_left: Enum.count(arrived, &(&1 == :left)),
      trays_served: Enum.count(events, &(&1.type == :tray_served)),
      npc_plans: Enum.count(events, &(&1.type == :npc_planned))
    }
  end

  @doc """
  Runs `actions` against a freshly stocked hall. Returns `%{state:, events:,
  batches:, commands:, outcomes:, setup_count:, stats:}`: `batches` starts
  with the whole setup log as one batch, then one batch per accepted command;
  `commands` is `[{command, ctx}]` in decision order, the first `setup_count`
  of them the fixture setup, and `outcomes` the pure outcome of each; `stats`
  counts `:stale_rejected` expected rejections. Options: `:catalog` (default
  `catalog/0`).
  """
  def run(actions, opts \\ []) do
    {world, setup} = setup(Keyword.get(opts, :catalog, catalog()))
    {batches, n} = initial_batches(world)
    acc = %{commands: setup, stale_rejected: 0}
    {state, batches, _n, acc} = Enum.reduce(actions, {elem(world, 0), batches, n, acc}, &step/2)
    {commands, outcomes} = acc.commands |> Enum.reverse() |> Enum.unzip()

    %{
      state: state,
      batches: batches,
      events: Enum.flat_map(batches, & &1),
      commands: commands,
      outcomes: outcomes,
      setup_count: length(setup),
      stats: %{stale_rejected: acc.stale_rejected}
    }
  end

  @doc """
  Workflow envelopes for recorded commands, in order. Should the interpreter
  ever give two recorded commands the same ID, the workflow (which binds an
  ID to one request) would see a conflict, so the `k`-th repeat of an ID
  (k >= 1) is renamed `"<id>/<k>"`. Every other ID is kept, and all stay
  within the workflow's 1..64 printable bytes.
  """
  def envelopes(commands) do
    {envelopes, _seen} =
      Enum.map_reduce(commands, %{}, fn {command, ctx}, seen ->
        repeat = Map.get(seen, ctx.command_id, 0)
        id = if repeat == 0, do: ctx.command_id, else: "#{ctx.command_id}/#{repeat}"
        {%{command_id: id, actor: ctx.actor, command: command}, Map.put(seen, ctx.command_id, repeat + 1)}
      end)

    envelopes
  end

  # The fixture world, built step by step so each setup command is recorded.
  defp setup(catalog) do
    [catalog: catalog]
    |> stocked_world_steps()
    |> Kernel.++(npc_create_steps(catalog))
    |> Enum.reduce({{nil, []}, []}, fn step, {{state, log}, recorded} ->
      {command, actor, id} = step.(state)
      context = ctx(actor, id)

      case Hall.execute(state, command, context) do
        {:ok, state, events} -> {{state, log ++ events}, [{{command, context}, :accepted} | recorded]}
        {:error, reason} -> flunk("#{inspect(elem(command, 0))} rejected: #{inspect(reason)}")
      end
    end)
  end

  defp initial_batches({_state, log}), do: {[log], 1}

  # -- interpreter ------------------------------------------------------------------

  defp step(action, {state, batches, n, acc}) do
    id = "c#{n}"

    case command(state, action, id) do
      nil ->
        {state, batches, n + 1, acc}

      {:expect_reject, cmd, actor, reason} ->
        assert {:error, ^reason} = Hall.decide(state, cmd, ctx(actor, id))
        acc = record(acc, cmd, ctx(actor, id), {:rejected, reason})
        {state, batches, n + 1, %{acc | stale_rejected: acc.stale_rejected + 1}}

      # Each part is planned against the state the earlier parts reached; its
      # moves are numbered `<id>.<m>` unless the move names its own ID.
      {:sequence, parts} ->
        Enum.reduce(parts, {state, batches, n + 1, acc}, &run_part(&1, &2, id))

      {cmd, actor} ->
        apply_command(state, batches, n + 1, acc, cmd, actor, id)
    end
  end

  defp run_part({:action, action}, {st, _bs, _m, _acc} = run, id) do
    case command(st, action, id) do
      nil -> run
      {cmd, actor} -> move(run, cmd, actor, id)
    end
  end

  defp run_part(:desserts, {st, _bs, _m, _acc} = run, id),
    do: Enum.reduce(dessert_answers(st), run, fn {cmd, actor}, run -> move(run, cmd, actor, id) end)

  defp run_part({:wait, ms}, {st, _bs, _m, _acc} = run, id),
    do: move(run, advance_by(st, ms), {:system, :scheduler}, id)

  defp run_part({:advance_to_hall, at_fun}, {st, _bs, _m, _acc} = run, id) do
    case at_fun.(st) do
      at when at > st.now -> move(run, advance_to_hall(at), {:system, :scheduler}, id)
      _ -> run
    end
  end

  defp run_part({:restock, recipes, portions}, {st, _bs, _m, _acc} = run, id),
    do: Enum.reduce(restock(st, recipes, portions), run, fn {cmd, actor}, run -> move(run, cmd, actor, id) end)

  # Each due NPC's plan, decided against the state the previous NPC's plan reached.
  defp run_part(:npc_plans, {st, _bs, _m, _acc} = run, _id) do
    st.npcs
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce(run, fn op, {st, _bs, _m, _acc} = run ->
      case npc_plan(st, op) do
        nil -> run
        {cmd, actor, npc_id} -> move(run, cmd, actor, npc_id, :own_id)
      end
    end)
  end

  # Advance in `step_ms` service steps, at most `max` times, until the guest's
  # visit reaches `goal` (`:offered`: a dessert offer is open; `:done`: no
  # active visit), the visit ends, or the hall closes for cleaning.
  defp run_part({:until_guest, g, goal, step_ms, max}, {st, _bs, _m, _acc} = run, id) do
    visit = st.visits[st.active_visits[Enum.at(@guests, g)]]

    reached =
      visit == nil or st.access == :cleaning or (goal == :offered and visit.dessert == :offered)

    if reached or max == 0 do
      run
    else
      run
      |> move(advance_by(st, step_ms), {:system, :scheduler}, id)
      |> then(&run_part({:until_guest, g, goal, step_ms, max - 1}, &1, id))
    end
  end

  defp move({st, bs, m, acc}, cmd, actor, id), do: apply_command(st, bs, m + 1, acc, cmd, actor, "#{id}.#{m}")
  defp move({st, bs, m, acc}, cmd, actor, own_id, :own_id), do: apply_command(st, bs, m + 1, acc, cmd, actor, own_id)

  defp apply_command(state, batches, n, acc, cmd, actor, id) do
    case Hall.decide(state, cmd, ctx(actor, id)) do
      {:ok, events} ->
        state = Hall.replay(events, state)
        batches = batches ++ [events]

        case Oracle.violations(state, Enum.concat(batches)) do
          [] -> {state, batches, n, record(acc, cmd, ctx(actor, id), :accepted)}
          problems -> flunk("after #{inspect(cmd)}: #{inspect(problems)}")
        end

      {:error, reason} ->
        {state, batches, n, record(acc, cmd, ctx(actor, id), {:rejected, reason})}
    end
  end

  defp record(acc, command, context, outcome), do: %{acc | commands: [{{command, context}, outcome} | acc.commands]}

  defp command(state, {:advance, ms}, _id),
    do: {{:advance_clock, %{to_service_ms: Clock.service_ms(state.now) + ms}}, {:system, :scheduler}}

  defp command(state, {:advance_to, which, offset}, _id) do
    boundary =
      if which == :cleaning_start, do: Clock.next_cleaning_start(state.now), else: Clock.next_cleaning_end(state.now)

    target = max(Clock.service_ms(boundary) + offset, Clock.service_ms(state.now))
    {{:advance_clock, %{to_service_ms: target}}, {:system, :scheduler}}
  end

  defp command(state, {:request, idx, qty}, _id) do
    product = state.catalog.products |> Map.keys() |> Enum.sort() |> Enum.at(idx)
    scale = if state.catalog.products[product].unit == :each, do: max(div(qty, 20), 1), else: qty
    {request(product, scale), {:principal, "alice"}}
  end

  # A full market clearing: advance to the next clearing instant, which fills or
  # expires every pending purchase request.
  defp command(state, {:market_clear}, _id),
    do: {advance_to_hall(state.market.next_clear_at), {:system, :scheduler}}

  # Cancel one of alice's pending requests (by index over pending products).
  defp command(state, {:cancel_request, idx}, _id) do
    case state.market.by_key |> Map.keys() |> Enum.filter(&(elem(&1, 0) == "r1")) |> Enum.sort() do
      [] ->
        nil

      keys ->
        {"r1", product} = Enum.at(keys, rem(idx, length(keys)))
        {{:cancel_purchase_request, %{restaurant_id: "r1", product: product}}, {:principal, "alice"}}
    end
  end

  # Through the next lunch peak (12:00 to 13:00 hall time; from now if the
  # peak is under way): advance to its start, restock alice's three mains,
  # run the due NPC plans, then advance to 13:00. Stream arrivals choose,
  # are admitted or leave, and the automatic kitchen cooks and serves them;
  # the restock fills at the first clearing of the peak.
  defp command(_state, {:meal_peak}, _id) do
    {:sequence,
     [
       {:advance_to_hall, &peak_start/1},
       {:restock, @mains, 12},
       :npc_plans,
       {:advance_to_hall, &(Clock.day_of(&1.now) * Clock.day() + 13 * Clock.hour())}
     ]}
  end

  # To the next hour boundary, then each due NPC's plan through the planner,
  # submitted as the authority would (actor `{:npc, op}`, ID `npc:<op>:<slot>`).
  defp command(_state, {:npc_slot}, _id) do
    {:sequence,
     [
       {:advance_to_hall, &((div(&1.now, Clock.hour()) + 1) * Clock.hour())},
       :npc_plans
     ]}
  end

  # A whole guest dessert course, so desserts are served in most runs rather
  # than only when random steps line up: clear of cleaning, open and restock
  # alice's stall for bean tacos and arroz con leche, fill at a clearing, fund
  # and seat the guest, wait for the dessert offer, accept it, and wait until
  # the visit is finalized.
  defp command(_state, {:dessert_course, g}, _id) do
    {:sequence,
     [
       {:action, {:clear_of_cleaning, 2 * Clock.hour()}},
       {:action, {:stall, :open_stall}},
       {:restock, ["bean_tacos", "arroz_con_leche"], 4},
       {:action, {:market_clear}},
       {:action, {:grant, g, 2_500}},
       {:action, {:guest_visit, g, 0, nil, 0, false}},
       {:until_guest, g, :offered, 2_000, 60},
       :desserts,
       {:until_guest, g, :done, 2_000, 60}
     ]}
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
        stall_id: @stall,
        main: Enum.at(@mains, m),
        drink: drink,
        profile_id: Enum.at(@profiles, p)
      }}, {:system, :demand}}
  end

  defp command(state, {:guest_visit, g, m, drink, p, stale}, _id) do
    guest = Enum.at(@guests, g)
    {:ok, req} = Dietary.requirement(state.catalog, Enum.at(@profiles, p))
    payload = %{source: :guest, stall_id: @stall, main: Enum.at(@mains, m), drink: drink, profile_id: req.profile_id}

    case Offers.quote_tray(state, @stall, payload.main, drink, %{requirement: req, carbs_reserved: 0, carbs_served: 0}) do
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

  # Let the automatic kitchen work for `ms` available-service milliseconds: a
  # short advance, at most about eight game minutes (one tray's work).
  defp command(state, {:wait, ms}, id), do: command(state, {:advance, ms}, id)

  # A service cycle: let waiting work cook and be served, answer any dessert
  # offers, then let the desserts (and later trays) be served. Later moves are
  # planned against the state reached after earlier ones.
  defp command(_state, {:cycle, ms, desserts}, _id) do
    answer = if desserts, do: [:desserts], else: []
    {:sequence, [{:wait, ms}] ++ answer ++ [{:wait, ms}]}
  end

  # A funded guest orders and cancels before the kitchen starts on it (the
  # next advance would start preparation and close voluntary cancellation).
  defp command(_state, {:regret, g, m, drink, p}, _id) do
    {:sequence,
     [
       {:action, {:grant, g, 2_500}},
       {:action, {:guest_visit, g, m, drink, p, false}},
       {:action, {:cancel_own, g}}
     ]}
  end

  defp command(state, {:cancel_own, g}, _id) do
    guest = Enum.at(@guests, g)

    with vid when vid != nil <- state.active_visits[guest],
         tid when tid != nil <- state.visits[vid].tray do
      {{:cancel_tray, %{tray_id: tid}}, {:principal, guest}}
    else
      _ -> nil
    end
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

  defp command(_state, {:stall, cmd}, _id), do: {{cmd, %{stall_id: @stall}}, {:principal, "alice"}}

  # Never generated by `action/0`: a caller appends it to move a trace clear of the cleaning
  # window before service it needs. While cleaning, or when the next 03:00 cutoff is within
  # `margin_ms`, advance just past the next 05:00 reopening; otherwise issue no command.
  defp command(state, {:clear_of_cleaning, margin_ms}, _id) do
    if state.access == :cleaning or Clock.service_cutoff(state.now) - state.now < margin_ms do
      {{:advance_clock, %{to_service_ms: Clock.service_ms(Clock.next_cleaning_end(state.now)) + 1}},
       {:system, :scheduler}}
    end
  end

  # An unrelated principal attempting owner or wallet operations.
  defp command(_state, {:intrude, which}, _id) do
    cmd =
      case which do
        0 ->
          {:submit_purchase_request, %{restaurant_id: "r1", product: "sugar", qty: 1, max_price_per_kunit: 1_000_000}}

        1 ->
          {:set_menu_price, %{restaurant_id: "r1", recipe_id: "bean_tacos", price: 1}}

        2 ->
          {:close_stall, %{stall_id: @stall}}

        3 ->
          {:grant_allowance, %{principal: "mallory", amount: 100}}
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

  # -- macro helpers ----------------------------------------------------------------

  defp advance_by(state, ms), do: {:advance_clock, %{to_service_ms: Clock.service_ms(state.now) + ms}}

  # Hall instants used here (clearings, whole hours) are whole service milliseconds.
  defp advance_to_hall(at), do: {:advance_clock, %{to_service_ms: Clock.service_ms(at)}}

  defp request(product, qty),
    do:
      {:submit_purchase_request, %{restaurant_id: "r1", product: product, qty: qty, max_price_per_kunit: 1_000_000_000}}

  # One request per primary product of `recipes`, for `portions` of each.
  defp restock(state, recipes, portions) do
    recipes
    |> Enum.flat_map(&state.catalog.recipes[&1].lines)
    |> Enum.reduce(%{}, fn line, acc -> Map.update(acc, line.product, line.qty, &(&1 + line.qty)) end)
    |> Enum.sort()
    |> Enum.map(fn {product, qty} -> {request(product, qty * portions), {:principal, "alice"}} end)
  end

  defp peak_start(state) do
    day = Clock.day_of(state.now)

    if Clock.time_of_day(state.now) < 13 * Clock.hour(),
      do: day * Clock.day() + 12 * Clock.hour(),
      else: (day + 1) * Clock.day() + 12 * Clock.hour()
  end

  # The authority's plan for a due NPC: the planner on the public view, its own
  # restaurant, its profile and its PRNG state, for the latest whole-hour slot.
  defp npc_plan(state, op) do
    npc = state.npcs[op]

    if npc.next_slot_at <= state.now do
      slot = div(state.now, Clock.hour()) * Clock.hour()
      profile = Enum.find(state.catalog.npc_profiles, &(&1.id == npc.profile_id))
      own = state.restaurants[npc.restaurant_id]
      {actions, rng} = Planner.plan(PublicView.build(state), own, profile, state.catalog, npc.rng)
      plan = %{operator: op, slot: slot, actions: actions, rng: rng}
      {{:npc_plan, plan}, {:npc, op}, "npc:#{op}:#{slot}"}
    end
  end

  # The authority's NPC bootstrap: one restaurant per catalog NPC profile, in ID
  # order, at the slot the planner chooses, with the first starter recipe's cuisine.
  defp npc_create_steps(catalog) do
    cuisine = catalog.recipes |> Map.values() |> Enum.filter(& &1.starter) |> Enum.min_by(& &1.id) |> Map.get(:cuisine)

    for profile <- Enum.sort_by(catalog.npc_profiles, & &1.id) do
      fn state ->
        slot = Planner.choose_slot(PublicView.build(state), state.layout, profile)
        payload = %{restaurant_id: "npc-#{profile.id}", stall_id: slot, name: "NPC #{profile.id}", cuisine: cuisine}
        {{:create_restaurant, payload}, {:npc, profile.id}, "npc:#{profile.id}:create"}
      end
    end
  end
end
