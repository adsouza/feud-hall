defmodule FeudHall.Domain.Hall.Settlement do
  @moduledoc """
  Builds the complete event batches that settle trays, desserts, and visits.

  Commands and clock boundaries share these builders so a voluntary
  cancellation, a missed deadline, ready-food expiry, and the 03:00 cleaning
  cutoff all release exactly the same resources. Each builder applies its own
  intermediate events with the evolver, so a later event in the batch (such as
  finalization) is computed from the settled candidate state.

  Recognition: each visit finalizes once with normalized main:drink:dessert
  weights over accepted components. Components canceled by scheduled cleaning
  or by the guest are omitted; other failures score zero. Scores are integers
  in hundredths of a quality point (0..10000).
  """

  alias FeudHall.Domain.{Clock, Offers}
  alias FeudHall.Domain.Hall.Evolver

  @doc "Cancels an unserved tray and finalizes its visit."
  def cancel_tray(state, tray, reason) do
    cancelled = %{
      type: :tray_cancelled,
      tray_id: tray.id,
      reason: reason,
      components: Enum.map(tray.components, &cancel_component(state, &1))
    }

    state1 = Evolver.evolve(state, cancelled)
    [cancelled, finalize_event(state1, state1.visits[tray.visit], visit_reason(reason))]
  end

  @doc "Cancels an accepted dessert and finalizes its visit."
  def cancel_dessert(state, order, reason) do
    cancelled = Map.merge(%{type: :dessert_cancelled, reason: reason}, cancel_component(state, order.id))
    state1 = Evolver.evolve(state, cancelled)

    reason =
      case reason do
        :cleaning -> :cleaning
        :guest_cancelled -> :dessert_cancelled
        _ -> :dessert_failed
      end

    [cancelled, finalize_event(state1, state1.visits[order.visit], reason)]
  end

  @doc "Serves a ready tray, then offers dessert or finalizes the visit."
  def serve_tray(state, tray) do
    served = %{
      type: :tray_served,
      tray_id: tray.id,
      components:
        Enum.map(tray.components, fn id ->
          o = state.orders[id]
          %{order_id: id, price: o.price, cost: o.consumed_cost, carbs_mg: o.carbs_mg}
        end)
    }

    state1 = Evolver.evolve(state, served)
    visit = state1.visits[tray.visit]

    if dessert_eligible?(state1, visit) do
      cutoff = Clock.service_cutoff(state1.now)
      window = Clock.service_duration(state1.catalog.rules.dessert_window_service_ms)
      [served, %{type: :dessert_offered, visit_id: visit.id, deadline: min(state1.now + window, cutoff)}]
    else
      [served, finalize_event(state1, visit, :completed)]
    end
  end

  @doc "Serves an accepted dessert and finalizes its visit."
  def serve_dessert(state, order) do
    served = %{
      type: :dessert_served,
      order_id: order.id,
      price: order.price,
      cost: order.consumed_cost,
      carbs_mg: order.carbs_mg
    }

    state1 = Evolver.evolve(state, served)
    [served, finalize_event(state1, state1.visits[order.visit], :completed)]
  end

  @doc "The single finalization fact for a visit, from settled state."
  def finalize_event(state, visit, reason) do
    weights = state.catalog.rules.course_weights

    components =
      visit
      |> order_ids(state)
      |> Enum.map(fn id ->
        o = state.orders[id]
        {outcome, score} = course_outcome(o)
        %{order_id: id, kind: o.kind, weight: weights[o.kind], outcome: outcome, score: score}
      end)

    scored = Enum.filter(components, &is_integer(&1.score))
    total_weight = scored |> Enum.map(& &1.weight) |> Enum.sum()

    score =
      if total_weight == 0,
        do: nil,
        else: div(Enum.sum(Enum.map(scored, &(&1.weight * &1.score * 100))), total_weight)

    %{
      type: :visit_finalized,
      visit_id: visit.id,
      reason: reason,
      components: components,
      score: score,
      competitive: visit.source == :simulated and score != nil
    }
  end

  defp cancel_component(state, order_id) do
    o = state.orders[order_id]
    %{order_id: order_id, released: o.reservations, waste_cost: o.consumed_cost}
  end

  defp order_ids(visit, state) do
    tray_orders = if visit.tray, do: state.trays[visit.tray].components, else: []
    tray_orders ++ List.wrap(visit.dessert_order)
  end

  defp course_outcome(%{status: :served, quality: q}), do: {:served, q}
  defp course_outcome(%{status: :cancelled, cancel_reason: :cleaning}), do: {:cleaning_exempt, nil}
  defp course_outcome(%{status: :cancelled, cancel_reason: :guest_cancelled}), do: {:guest_cancelled, nil}
  defp course_outcome(%{status: :cancelled}), do: {:failed, 0}

  defp visit_reason(:cleaning), do: :cleaning
  defp visit_reason(:guest_cancelled), do: :guest_cancelled
  defp visit_reason(_), do: :main_failed

  # A served main unlocks one optional same-stall dessert only when it can be
  # quoted (stall open, unlocked, on menu, compatible, reservable, finishes
  # before cleaning) and the diner can afford it.
  defp dessert_eligible?(state, visit) do
    case Offers.quote_dessert(state, visit) do
      {:ok, quote} -> affordable?(state, visit, quote.total)
      {:error, _} -> false
    end
  end

  defp affordable?(_state, %{source: :simulated} = v, price), do: v.budget_committed + price <= v.budget

  defp affordable?(state, %{source: :guest} = v, price) do
    free =
      state.wallets
      |> Map.get(v.principal, %{slices: %{}})
      |> Map.get(:slices)
      |> Map.values()
      |> Enum.map(&(&1.amount - &1.reserved))
      |> Enum.sum()

    free >= price
  end
end
