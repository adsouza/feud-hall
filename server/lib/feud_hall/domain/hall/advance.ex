defmodule FeudHall.Domain.Hall.Advance do
  @moduledoc """
  Clock advancement through due boundaries, as one deterministic batch.

  The scheduler supplies only a target; the domain walks every due boundary in
  order and records the outcome of each. Boundaries due at one timestamp are
  taken by class, lower first, and within a class by stable entity ID:

    1. raw-stock and ready-food expiry (expiry wins an exact freshness tie);
    2. the 03:00 cleaning cutoff, which closes customer access and cancels all
       unserved customer work, queued or in progress;
    3. kitchen stage completions and counter handover completions (service);
    4. diner deadlines and dessert-offer timeouts (a deadline falls at its
       instant, after same-timestamp service, so service exactly at the
       deadline wins);
    5. the 05:00 reopening of customer access;
    6. the day boundary at each 00:00: `day_closed` fixes the next day's scale,
       replenishes the market and publishes the summary (so a same-instant
       clearing sees the replenished stock);
    7. market clearing every `clear_every_hall_ms`, cleaning included: one
       `market_cleared` batch that settles every pending purchase request;
    8. a simulated arrival at `demand.next_arrival_at` (see
       `FeudHall.Domain.Demand`): the diner is drawn from the demand PRNG,
       chooses through `FeudHall.Domain.Choice`, and a chosen tray is admitted
       through `FeudHall.Domain.Hall.Admission` exactly as a guest's would be;
       `diner_arrived` records the draws, the outcome and the PRNG
       continuation, followed by the admission events;
    9. kitchen dispatch: start queued stages on free stations and select the
       counter's next ready item, only while customer access is open.

  Each class is one entry in `classes/0`: a function from state to the
  `{at, entity_id, ref}` boundaries it has due, with a matching `handle/2`
  clause. Dispatch is due at the current instant whenever a stall can start
  work, so work accepted by a command starts at the next advance, at the
  acceptance instant. Commands at the same timestamp are decided after this
  batch commits.
  """

  alias FeudHall.Domain.{Choice, Clock, Demand, Dietary, Inventory, Kitchen, Market}
  alias FeudHall.Domain.Hall.{Admission, Evolver, Settlement}

  @doc "Returns the events that advance `state` to hall time `target`."
  def run(state, target), do: loop(state, target, [])

  @doc """
  The boundary classes in same-timestamp order: `{class, due_fun}` where
  `due_fun.(state)` lists `{at, entity_id, ref}`.
  """
  def classes do
    [
      {1, &expiries/1},
      {2, &cleaning_start/1},
      {3, &kitchen_completions/1},
      {4, &deadlines/1},
      {5, &reopening/1},
      {6, &day_boundary/1},
      {7, &market_clearing/1},
      {8, &arrival/1},
      {9, &dispatch/1}
    ]
  end

  # `acc` holds the batches handled so far, newest first.
  defp loop(state, target, acc) do
    case next_due(state, target) do
      nil ->
        tail = if target > state.now, do: [clock_advanced(state, target)], else: []
        [tail | acc] |> Enum.reverse() |> Enum.concat()

      {at, _class, _id, ref} ->
        tick = if at > state.now, do: [clock_advanced(state, at)], else: []
        state = Enum.reduce(tick, state, &Evolver.evolve(&2, &1))
        events = handle(state, ref)
        state = Enum.reduce(events, state, &Evolver.evolve(&2, &1))
        loop(state, target, [events, tick | acc])
    end
  end

  # Who operated over the interval is decided from the state it starts in and
  # recorded; the evolver only reads it. Every state change inside a day is a
  # boundary or a command, so the list is constant between them. The list is
  # written only when it differs from the last one recorded (`demand.operating`),
  # which depends on the state alone, so partitioning a span changes which
  # `clock_advanced` events carry it but neither any other event nor the state.
  defp clock_advanced(state, to),
    do: Map.merge(%{type: :clock_advanced, to: to}, Demand.operating_change(state.demand, Demand.operating(state)))

  defp next_due(state, target) do
    classes()
    |> Enum.flat_map(fn {class, due} -> for {at, id, ref} <- due.(state), do: {at, class, id, ref} end)
    |> Enum.filter(fn {at, _, _, _} -> at <= target end)
    |> Enum.min(fn -> nil end)
  end

  # Class 1.
  defp expiries(state) do
    batches =
      for {rid, r} <- state.restaurants, {bid, b} <- r.batches, do: {b.expires_at, bid, {:batch, rid, bid}}

    ready = for {oid, o} <- state.orders, o.status == :ready, do: {o.ready_expires_at, oid, {:ready, oid}}
    batches ++ ready
  end

  # Class 2.
  defp cleaning_start(%{access: :open, now: now}),
    do: [{Clock.service_cutoff(now), "cleaning", {:cleaning_start}}]

  defp cleaning_start(_state), do: []

  # Class 3.
  defp kitchen_completions(state) do
    stages =
      for {oid, o} <- state.orders, o.status in [:prep, :finish], do: {o.stage_done_at, oid, {:stage_done, oid}}

    handovers =
      for {sid, %{counter: %{done_at: at}}} <- state.stalls, do: {at, sid, {:handover_done, sid}}

    stages ++ handovers
  end

  # Class 4.
  defp deadlines(state) do
    trays = for {tid, t} <- state.trays, t.status == :accepted, do: {t.deadline, tid, {:tray_deadline, tid}}

    desserts =
      for {oid, o} <- state.orders,
          o.kind == :dessert,
          o.status in Kitchen.stages(),
          do: {o.deadline, oid, {:dessert_deadline, oid}}

    offers =
      for {vid, v} <- state.visits,
          v.status == :active,
          v.dessert == :offered,
          do: {v.dessert_offer_deadline, vid, {:offer_timeout, vid}}

    trays ++ desserts ++ offers
  end

  # Class 5.
  defp reopening(%{access: :cleaning, now: now}),
    do: [{Clock.cleaning_end_of(Clock.day_of(now)), "cleaning", {:cleaning_end}}]

  defp reopening(_state), do: []

  # Class 6: each midnight, once. Halls recorded without demand rules have none.
  defp day_boundary(%{demand: %{next_day_at: at}, catalog: catalog}) do
    if Demand.closes_days?(catalog), do: [{at, "day", {:day_close}}], else: []
  end

  defp day_boundary(_state), do: []

  # Class 7: every `clear_every_hall_ms`, cleaning included, whether or not
  # requests are pending. Halls recorded without market rules never clear.
  defp market_clearing(%{market: %{next_clear_at: at}, catalog: catalog}) do
    if Market.clearing?(catalog), do: [{at, "market", {:market_clear}}], else: []
  end

  defp market_clearing(_state), do: []

  # Class 8: the next simulated arrival, if the day's quotas hold one.
  defp arrival(%{demand: demand}) do
    case Map.get(demand, :next_arrival_at) do
      nil -> []
      at -> [{at, "arrival", {:arrival}}]
    end
  end

  # Class 9.
  defp dispatch(%{access: :open} = state) do
    for sid <- Kitchen.busy_stalls(state), Kitchen.next_start(state, sid) != nil, do: {state.now, sid, {:dispatch, sid}}
  end

  defp dispatch(_state), do: []

  # -- boundary handlers ----------------------------------------------------------

  defp handle(state, {:batch, rid, bid}) do
    affected =
      state.orders
      |> Map.values()
      |> Enum.filter(&(&1.status == :queued_prep and Enum.any?(&1.reservations, fn c -> c.batch_id == bid end)))
      |> Enum.map(& &1.id)
      |> Enum.sort()

    {state, events} =
      Enum.reduce(affected, {state, []}, fn oid, {st, acc} ->
        # A sibling component's cancellation may already have settled this one.
        order = st.orders[oid]

        if order.status == :queued_prep and Enum.any?(order.reservations, &(&1.batch_id == bid)) do
          events = replace_or_cancel(st, rid, bid, order)
          {Enum.reduce(events, st, &Evolver.evolve(&2, &1)), acc ++ events}
        else
          {st, acc}
        end
      end)

    batch = state.restaurants[rid].batches[bid]
    events ++ [%{type: :stock_spoiled, restaurant_id: rid, batch_id: bid, qty: batch.qty, cost: batch.cost}]
  end

  defp handle(state, {:ready, oid}), do: cancel_owner(state, state.orders[oid], :ready_food_expired)

  defp handle(state, {:cleaning_start}) do
    started = %{type: :hall_cleaning_started, day: Clock.day_of(state.now), at: state.now}
    state = Evolver.evolve(state, started)

    trays = for {_, t} <- Enum.sort(state.trays), t.status == :accepted, do: {:tray, t.id}

    desserts =
      for {_, o} <- Enum.sort(state.orders),
          o.kind == :dessert,
          o.status in Kitchen.stages(),
          do: {:dessert, o.id}

    offers =
      for {_, v} <- Enum.sort(state.visits), v.status == :active, v.dessert == :offered, do: {:offer, v.id}

    {_, events} =
      Enum.reduce(trays ++ desserts ++ offers, {state, []}, fn item, {st, acc} ->
        events = cleaning_settlement(st, item)
        {Enum.reduce(events, st, &Evolver.evolve(&2, &1)), acc ++ events}
      end)

    [started | events]
  end

  defp handle(state, {:cleaning_end}),
    do: [%{type: :hall_cleaning_ended, day: Clock.day_of(state.now), at: state.now}]

  defp handle(state, {:stage_done, oid}) do
    order = state.orders[oid]

    case order.status do
      :prep ->
        [%{type: :stage_completed, order_id: oid, stage: :prep}]

      :finish ->
        holding = state.catalog.recipes[order.recipe_id].holding_ms
        [%{type: :stage_completed, order_id: oid, stage: :finish, expires_at: state.now + holding}]
    end
  end

  # Expiry, deadlines and the cutoff come first at this instant and release
  # the counter, so an item still in hand here is fresh, in time and open.
  defp handle(state, {:handover_done, sid}) do
    case state.stalls[sid].counter.item do
      {:tray, tid} -> Settlement.serve_tray(state, state.trays[tid])
      {:dessert, oid} -> Settlement.serve_dessert(state, state.orders[oid])
    end
  end

  defp handle(state, {:day_close}), do: [Demand.close_day(state)]

  defp handle(state, {:market_clear}), do: [Market.clear(state)]

  defp handle(state, {:arrival}) do
    day = Clock.day_of(state.now)
    seq = state.demand.arrival_seq
    arrival_id = "A#{day}-#{seq}"
    {draw, rng} = Demand.draw_diner(state.catalog, state.demand.rng)
    {:ok, requirement} = Dietary.requirement(state.catalog, draw.profile_id)

    diner = %{
      segment: draw.segment,
      budget: draw.budget,
      requirement: requirement,
      patience_hall_ms: draw.patience_hall_ms,
      drink?: draw.drink?
    }

    {choice, rng} = Choice.choose(state, diner, rng)

    {outcome, reason, admission} =
      case choice do
        {:leave, reason} ->
          {:left, reason, []}

        {:stall, stall_id, main, drink} ->
          request = %{
            source: :simulated,
            principal: "diner:D#{day}-#{seq}",
            budget: draw.budget,
            stall_id: stall_id,
            main: main,
            drink: drink,
            profile_id: draw.profile_id,
            confirmed: nil,
            deadline_cap: min(state.now + draw.patience_hall_ms, Clock.service_cutoff(state.now)),
            dessert_appetite?: draw.dessert_appetite?
          }

          # Choice quoted this tray against the same state, so admission
          # should not fail; if it does, the diner leaves instead.
          case Admission.admit(state, request, arrival_id) do
            {:ok, events} -> {:admitted, nil, events}
            {:error, _} -> {:left, :admission_failed, []}
          end
      end

    arrived = %{
      type: :diner_arrived,
      arrival_id: arrival_id,
      segment: draw.segment.id,
      budget: draw.budget,
      patience_hall_ms: draw.patience_hall_ms,
      profile_id: draw.profile_id,
      drink?: draw.drink?,
      dessert_appetite?: draw.dessert_appetite?,
      outcome: outcome,
      reason: reason,
      rng: rng
    }

    [arrived | admission]
  end

  defp handle(state, {:dispatch, sid}), do: dispatch_stall(state, sid, [])

  defp handle(state, {:tray_deadline, tid}), do: Settlement.cancel_tray(state, state.trays[tid], :deadline_missed)

  defp handle(state, {:dessert_deadline, oid}),
    do: Settlement.cancel_dessert(state, state.orders[oid], :deadline_missed)

  defp handle(state, {:offer_timeout, vid}),
    do: [Settlement.finalize_event(state, state.visits[vid], :dessert_offer_expired)]

  defp cleaning_settlement(state, {:tray, tid}), do: Settlement.cancel_tray(state, state.trays[tid], :cleaning)
  defp cleaning_settlement(state, {:dessert, oid}), do: Settlement.cancel_dessert(state, state.orders[oid], :cleaning)

  defp cleaning_settlement(state, {:offer, vid}),
    do: [Settlement.finalize_event(state, state.visits[vid], :cleaning)]

  # Starts every piece of work the stall can take now, applying each start
  # before choosing the next so shared batches are costed in order.
  defp dispatch_stall(state, sid, acc) do
    case Kitchen.next_start(state, sid) do
      nil ->
        acc

      start ->
        event = start_event(state, sid, start)
        dispatch_stall(Evolver.evolve(state, event), sid, acc ++ [event])
    end
  end

  defp start_event(state, _sid, {:prep, oid}) do
    order = state.orders[oid]
    batches = state.restaurants[state.visits[order.visit].restaurant].batches

    consumed =
      Enum.map(order.reservations, fn claim ->
        %{
          batch_id: claim.batch_id,
          qty: claim.qty,
          cost: Inventory.consumption_cost(batches[claim.batch_id], claim.qty)
        }
      end)

    %{type: :stage_started, order_id: oid, stage: :prep, done_at: state.now + order.prep_ms, consumed: consumed}
  end

  defp start_event(state, _sid, {:finish, oid}),
    do: %{type: :stage_started, order_id: oid, stage: :finish, done_at: state.now + state.orders[oid].finish_ms}

  defp start_event(state, sid, {:handover, {kind, id}}),
    do: %{
      type: :handover_started,
      stall_id: sid,
      item: %{kind: kind, id: id},
      done_at: state.now + state.catalog.rules.handover_ms
    }

  # Expiring reserved stock may be replaced only by fresh stock of the same
  # bound product; otherwise the whole tray (or dessert) is cancelled.
  defp replace_or_cancel(state, rid, bid, order) do
    claim = Enum.find(order.reservations, &(&1.batch_id == bid))
    batches = state.restaurants[rid].batches
    product = batches[bid].product

    case Inventory.plan_reservation(batches, product, claim.qty, state.now, [bid]) do
      {:ok, claims} -> [%{type: :reservation_replaced, order_id: order.id, released: [claim], claimed: claims}]
      {:error, _} -> cancel_owner(state, order, :ingredient_expired)
    end
  end

  defp cancel_owner(state, %{tray: tid}, reason) when is_binary(tid),
    do: Settlement.cancel_tray(state, state.trays[tid], reason)

  defp cancel_owner(state, order, reason), do: Settlement.cancel_dessert(state, order, reason)
end
