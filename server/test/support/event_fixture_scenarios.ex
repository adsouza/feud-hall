defmodule FeudHall.EventFixtureScenarios do
  @moduledoc """
  Real events for the golden serialized fixtures under `test/fixtures/events`.

  One deterministic scenario drives the domain through every event type the
  shared simulation added (and the changed shapes worth pinning). Each entry
  pairs the first matching event with the state it evolves from, rebuilt by
  replaying the log before it. The committed JSON files are generated from
  these events (`write!/1`); the tests read the files, not the scenario, so a
  later change of tuning or of encoding cannot silently rewrite the golden
  bytes.

  The Milestone 1 / Project A events the decider no longer emits
  (`stock_purchased`, `preparation_started`, `preparation_completed`) are
  assembled from facts of real events of the same shape, following the base
  branch's decider, so historical decoding stays pinned. Likewise an earlier
  shape of a still-emitted event (`market_cleared` before it recorded
  `next_clear_at`).

  Regenerate (only when a golden shape is meant to change):

      MIX_ENV=test mix run --no-start -e 'FeudHall.EventFixtureScenarios.write!("test/fixtures/events")'
  """

  import FeudHall.Fixtures

  alias FeudHall.Domain.{Clock, Hall}
  alias FeudHall.Infrastructure.EventCodec

  @npc {:npc, "budget"}

  @doc "The scenario's final `{state, log}`."
  def world do
    world =
      stocked_world()
      |> run!(
        {:create_restaurant, %{restaurant_id: "npc-budget", stall_id: "s041", name: "NPC budget", cuisine: "mexican"}},
        @npc,
        "npc:budget:create"
      )
      |> run!(
        {:submit_purchase_request,
         %{restaurant_id: "r1", product: "sugar", qty: 10, max_price_per_kunit: 1_000_000_000}},
        owner(),
        "fx-request"
      )
      |> run!({:cancel_purchase_request, %{restaurant_id: "r1", product: "sugar"}}, owner(), "fx-cancel")
      |> grant("bob", 2_500, "fx-grant")
      |> guest_visit("bob", "fx-guest", "bean_tacos", "horchata")

    {state, _} = world
    guest_tray = tray_id("fx-guest")

    world
    |> serve_tray(guest_tray)
    |> simulated_visit("fx-dessert", "bean_tacos", nil, "unrestricted", 10_000, true)
    |> serve_tray(tray_id("visit-fx-dessert"))
    |> advance_hall(next_hour(state.now))
    |> plan_budget()
    |> advance_hall(Clock.day() + 24)
  end

  defp next_hour(now), do: (div(now, Clock.hour()) + 1) * Clock.hour()

  defp plan_budget({state, _} = world) do
    slot = state.npcs["budget"].next_slot_at

    run!(
      world,
      {:npc_plan,
       %{
         operator: "budget",
         slot: slot,
         actions: [{:set_menu_price, %{restaurant_id: "npc-budget", recipe_id: "bean_tacos", price: 777}}],
         rng: 5
       }},
      @npc,
      "npc:budget:#{slot}"
    )
  end

  # `{file name, event predicate}`: the first event matching each is the fixture. With
  # `{:after, name}` the search starts after an earlier selection's event.
  defp selections do
    [
      {"hall_initialized", &(&1.type == :hall_initialized)},
      {"clock_advanced_operating", &(&1.type == :clock_advanced and &1[:operating] not in [nil, []])},
      # The first interval after that one that restates nothing: it credits the recorded list.
      {"clock_advanced_unchanged", {:after, "clock_advanced_operating"},
       &(&1.type == :clock_advanced and not Map.has_key?(&1, :operating))},
      {"restaurant_created_npc", &(&1.type == :restaurant_created and &1[:owner_kind] == :npc)},
      {"purchase_requested", &(&1.type == :purchase_requested)},
      {"purchase_request_cancelled", &(&1.type == :purchase_request_cancelled)},
      {"market_cleared", &(&1.type == :market_cleared and &1.fills != [])},
      {"visit_admitted_simulated", &(&1.type == :visit_admitted and &1.source == :simulated)},
      {"tray_accepted", &(&1.type == :tray_accepted and is_integer(&1[:estimated_completion]))},
      {"stage_started_prep", &(&1.type == :stage_started and &1.stage == :prep)},
      {"stage_completed_prep", &(&1.type == :stage_completed and &1.stage == :prep)},
      {"stage_started_finish", &(&1.type == :stage_started and &1.stage == :finish)},
      {"stage_completed_finish", &(&1.type == :stage_completed and &1.stage == :finish)},
      {"handover_started", &(&1.type == :handover_started)},
      {"dessert_accepted", &(&1.type == :dessert_accepted and is_integer(&1[:estimated_completion]))},
      {"diner_arrived_admitted", &(&1.type == :diner_arrived and &1.outcome == :admitted)},
      {"diner_arrived_left", &(&1.type == :diner_arrived and &1.outcome == :left)},
      {"day_closed", &(&1.type == :day_closed)},
      {"npc_planned", &(&1.type == :npc_planned)}
    ]
  end

  # Historical events, built from a real event's facts: `{name, source selection name, builder}`.
  defp historical do
    [
      {"market_cleared_without_next_clear_at", "market_cleared",
       fn market_cleared, _log -> Map.delete(market_cleared, :next_clear_at) end},
      {"stock_purchased", "market_cleared",
       fn _market_cleared, log ->
         fill = log |> Enum.find(&(&1.type == :market_cleared and &1.fills != [])) |> Map.fetch!(:fills) |> hd()
         fill |> Map.delete(:request_id) |> Map.put(:type, :stock_purchased)
       end},
      {"preparation_started", "stage_started_prep",
       fn started, _log ->
         %{
           type: :preparation_started,
           order_id: started.order_id,
           consumed: started.consumed,
           ready_not_before: started.done_at
         }
       end},
      {"preparation_completed", "stage_completed_finish",
       fn completed, _log ->
         %{type: :preparation_completed, order_id: completed.order_id, expires_at: completed.expires_at}
       end}
    ]
  end

  @doc """
  Every fixture: `[%{name, event, pre}]` where `pre` is the hall state the event evolves from.
  """
  def entries do
    {_state, log} = world()

    indexed =
      Enum.reduce(selections(), [], fn selection, acc ->
        {name, from, matches?} =
          case selection do
            {name, {:after, earlier}, matches?} -> {name, Enum.find(acc, &(&1.name == earlier)).index + 1, matches?}
            {name, matches?} -> {name, 0, matches?}
          end

        offset = log |> Enum.drop(from) |> Enum.find_index(matches?) || raise "scenario produced no event for #{name}"
        acc ++ [%{name: name, index: from + offset}]
      end)

    real =
      for %{name: name, index: index} <- indexed,
          do: %{name: name, event: Enum.at(log, index), pre: replay(Enum.take(log, index))}

    historic =
      for {name, source, build} <- historical() do
        %{event: from, pre: pre} = Enum.find(real, &(&1.name == source))
        %{name: name, event: build.(from, log), pre: pre}
      end

    real ++ historic
  end

  defp replay([]), do: nil
  defp replay(events), do: Hall.replay(events)

  @doc "Writes one `<name>.json` per entry (the codec's exact bytes) into `dir`."
  def write!(dir) do
    File.mkdir_p!(dir)

    for %{name: name, event: event} <- entries(),
        do: File.write!(Path.join(dir, name <> ".json"), EventCodec.encode!(event))

    :ok
  end
end
