defmodule FeudHall.Domain.Hall.Advance do
  @moduledoc """
  Clock advancement through due boundaries, as one deterministic batch.

  The scheduler supplies only a target; the domain walks every due boundary in
  order and records the outcome of each. At a shared timestamp the order is:

    1. raw-stock and ready-food expiry (expiry wins an exact freshness tie);
    2. the 03:00 cleaning cutoff, which closes customer access before any
       same-timestamp service and cancels all unserved customer work;
    3. diner deadlines and dessert-offer timeouts (a tray deadline is missed
       only strictly after it, so service at the exact deadline wins);
    4. the 05:00 reopening of customer access.

  Ties within a class resolve by stable entity ID. Commands at the same
  timestamp are decided after this batch commits.
  """

  alias FeudHall.Domain.{Clock, Inventory}
  alias FeudHall.Domain.Hall.{Evolver, Settlement}

  @doc "Returns the events that advance `state` to hall time `target`."
  def run(state, target), do: loop(state, target, [])

  defp loop(state, target, acc) do
    case next_due(state, target) do
      nil ->
        tail = if target > state.now, do: [%{type: :clock_advanced, to: target}], else: []
        acc ++ tail

      {at, _class, ref} ->
        tick = if at > state.now, do: [%{type: :clock_advanced, to: at}], else: []
        state = Enum.reduce(tick, state, &Evolver.evolve(&2, &1))
        events = handle(state, ref)
        state = Enum.reduce(events, state, &Evolver.evolve(&2, &1))
        loop(state, target, acc ++ tick ++ events)
    end
  end

  defp next_due(state, target) do
    candidates =
      batch_expiries(state) ++
        ready_expiries(state) ++
        cleaning(state) ++ deadlines(state) ++ offer_timeouts(state)

    candidates
    |> Enum.filter(fn {at, _, _} -> at <= target end)
    |> Enum.min(fn -> nil end)
  end

  defp batch_expiries(state) do
    for {rid, r} <- state.restaurants, {bid, b} <- r.batches, do: {b.expires_at, 1, {:batch, rid, bid}}
  end

  defp ready_expiries(state) do
    for {oid, o} <- state.orders, o.status == :ready, do: {o.ready_expires_at, 1, {:ready, oid}}
  end

  defp cleaning(%{access: :open, now: now}), do: [{Clock.service_cutoff(now), 2, {:cleaning_start}}]

  defp cleaning(%{access: :cleaning, now: now}),
    do: [{Clock.cleaning_end_of(Clock.day_of(now)), 4, {:cleaning_end}}]

  defp deadlines(state) do
    trays = for {tid, t} <- state.trays, t.status == :accepted, do: {t.deadline + 1, 3, {:tray_deadline, tid}}

    desserts =
      for {oid, o} <- state.orders,
          o.kind == :dessert,
          o.status in [:reserved, :preparing, :ready],
          do: {o.deadline + 1, 3, {:dessert_deadline, oid}}

    trays ++ desserts
  end

  defp offer_timeouts(state) do
    for {vid, v} <- state.visits,
        v.status == :active,
        v.dessert == :offered,
        do: {v.dessert_offer_deadline, 3, {:offer_timeout, vid}}
  end

  # -- boundary handlers ----------------------------------------------------------

  defp handle(state, {:batch, rid, bid}) do
    affected =
      state.orders
      |> Map.values()
      |> Enum.filter(&(&1.status == :reserved and Enum.any?(&1.reservations, fn c -> c.batch_id == bid end)))
      |> Enum.map(& &1.id)
      |> Enum.sort()

    {state, events} =
      Enum.reduce(affected, {state, []}, fn oid, {st, acc} ->
        # A sibling component's cancellation may already have settled this one.
        order = st.orders[oid]

        if order.status == :reserved and Enum.any?(order.reservations, &(&1.batch_id == bid)) do
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
          o.status in [:reserved, :preparing, :ready],
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

  defp handle(state, {:tray_deadline, tid}), do: Settlement.cancel_tray(state, state.trays[tid], :deadline_missed)

  defp handle(state, {:dessert_deadline, oid}),
    do: Settlement.cancel_dessert(state, state.orders[oid], :deadline_missed)

  defp handle(state, {:offer_timeout, vid}),
    do: [Settlement.finalize_event(state, state.visits[vid], :dessert_offer_expired)]

  defp cleaning_settlement(state, {:tray, tid}), do: Settlement.cancel_tray(state, state.trays[tid], :cleaning)
  defp cleaning_settlement(state, {:dessert, oid}), do: Settlement.cancel_dessert(state, state.orders[oid], :cleaning)

  defp cleaning_settlement(state, {:offer, vid}),
    do: [Settlement.finalize_event(state, state.visits[vid], :cleaning)]

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
