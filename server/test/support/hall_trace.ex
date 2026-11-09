defmodule FeudHall.HallTrace do
  @moduledoc """
  Random hall command traces for the model-based properties: the symbolic
  action generator and the pure interpreter that runs a trace against
  `Hall.decide/3`.

  Symbolic actions pick concrete targets from current state by index, so
  shrinking removes actions without leaving dangling IDs. After every accepted
  command the independent oracle must report no violations.

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

  alias FeudHall.Domain.{Clock, Dietary, Hall, Offers}
  alias FeudHall.Domain.Content.SliceCatalog
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

      {:sequence, parts} ->
        Enum.reduce(parts, {state, batches, n + 1, acc}, fn part, {st, bs, m, acc} ->
          moves =
            case part do
              {:action, action} ->
                List.wrap(command(st, action, id))

              :desserts ->
                dessert_answers(st)

              {:wait, ms} ->
                [{{:advance_clock, %{to_service_ms: Clock.service_ms(st.now) + ms}}, {:system, :scheduler}}]
            end

          Enum.reduce(moves, {st, bs, m, acc}, fn {cmd, actor}, {st2, bs2, m2, acc2} ->
            apply_command(st2, bs2, m2 + 1, acc2, cmd, actor, "#{id}.#{m2}")
          end)
        end)

      {cmd, actor} ->
        apply_command(state, batches, n + 1, acc, cmd, actor, id)
    end
  end

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
        0 -> {:purchase_stock, %{restaurant_id: "r1", product: "sugar", qty: 1, max_price_per_kunit: 1_000_000}}
        1 -> {:set_menu_price, %{restaurant_id: "r1", recipe_id: "bean_tacos", price: 1}}
        2 -> {:close_stall, %{stall_id: @stall}}
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
end
