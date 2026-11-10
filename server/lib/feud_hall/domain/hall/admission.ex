defmodule FeudHall.Domain.Hall.Admission do
  @moduledoc """
  Pure quote, fund and reserve logic shared by every kind of diner.

  Human guests and simulated diners are admitted by exactly the same path:
  the tray (or dessert) is quoted from current state, its terms are bound,
  each course is funded, and its ingredient claims are reserved. Entity IDs
  are derived from `entity_id`, so a decision is deterministic and a retried
  command cannot mint a second order. Authorization of the caller stays in
  the decider; this module only decides facts.
  """

  alias FeudHall.Domain.{Dietary, Inventory, Offers, Substitution}

  @doc """
  Admits a visit and accepts its tray atomically.

  `deadline_cap`, when an integer, lowers the bound deadline to at most that
  hall time. A simulated diner's drawn `dessert_appetite?`, when given, is
  recorded on the visit.
  """
  def admit(state, p, entity_id) do
    %{source: source, principal: principal, budget: budget} = p

    with :ok <- ensure(id?(p[:stall_id]) and id?(p[:main]), :invalid_payload),
         :ok <- ensure(p[:drink] == nil or id?(p[:drink]), :invalid_payload),
         :ok <- ensure(not Map.has_key?(state.active_visits, principal), :visit_already_active),
         {:ok, requirement} <- Dietary.requirement(state.catalog, p[:profile_id]),
         blank = %{requirement: requirement, carbs_reserved: 0, carbs_served: 0},
         {:ok, quote} <- Offers.quote_tray(state, p.stall_id, p.main, p[:drink], blank),
         {:ok, bound} <- bind_deadline(source, quote, p[:confirmed]),
         deadline = cap_deadline(bound, p[:deadline_cap]),
         {:ok, funding} <- fund(state, source, principal, budget, quote) do
      visit_id = "V:" <> entity_id
      tray_id = "T:" <> entity_id

      admitted = %{
        type: :visit_admitted,
        visit_id: visit_id,
        source: source,
        principal: principal,
        restaurant_id: quote.restaurant_id,
        stall_id: quote.stall_id,
        requirement: requirement,
        budget: budget
      }

      admitted =
        if source == :simulated and is_boolean(p[:dessert_appetite?]),
          do: Map.put(admitted, :dessert_appetite?, p.dessert_appetite?),
          else: admitted

      batches = state.restaurants[quote.restaurant_id].batches

      case reserve_components(batches, quote.components, funding, state.now, entity_id) do
        {:ok, components} ->
          accepted = %{
            type: :tray_accepted,
            tray_id: tray_id,
            visit_id: visit_id,
            restaurant_id: quote.restaurant_id,
            stall_id: quote.stall_id,
            deadline: deadline,
            estimated_completion: quote.earliest_completion,
            components: components
          }

          {:ok, [admitted, accepted]}

        {:error, _} = error ->
          error
      end
    end
  end

  @doc "Accepts the optional dessert for an already-resolved, authorized visit."
  def accept_dessert(state, visit, confirmed, entity_id) do
    with :ok <- ensure(visit.dessert == :offered, :no_dessert_offer),
         :ok <- ensure(state.now < visit.dessert_offer_deadline, :dessert_offer_expired),
         {:ok, quote} <- Offers.quote_dessert(state, visit),
         {:ok, deadline} <- bind_deadline(visit.source, quote, confirmed),
         {:ok, funding} <- fund_dessert(state, visit, quote),
         batches = state.restaurants[visit.restaurant].batches,
         {:ok, [order]} <- reserve_components(batches, quote.components, funding, state.now, entity_id) do
      {:ok,
       [
         %{
           type: :dessert_accepted,
           visit_id: visit.id,
           deadline: deadline,
           estimated_completion: quote.earliest_completion,
           order: order
         }
       ]}
    end
  end

  defp cap_deadline(deadline, nil), do: deadline
  defp cap_deadline(deadline, cap) when is_integer(cap), do: min(deadline, cap)

  defp bind_deadline(:guest, quote, confirmed), do: Offers.check_confirmation(quote, confirmed)
  defp bind_deadline(:simulated, quote, _confirmed), do: {:ok, quote.deadline}

  # Guest courses reserve exact wallet slices (allowance before earned credit);
  # simulated courses must fit the visit's pinned budget.
  defp fund(state, :guest, principal, _budget, quote) do
    slices =
      state.wallets
      |> Map.get(principal, %{slices: %{}})
      |> Map.get(:slices)
      |> Enum.map(fn {id, s} -> {id, s.source, s.amount - s.reserved} end)
      |> Enum.filter(fn {_, _, free} -> free > 0 end)
      |> Enum.sort_by(fn {id, source, _} -> {if(source == :allowance, do: 0, else: 1), id} end)

    Enum.reduce_while(quote.components, {:ok, [], slices}, fn c, {:ok, acc, pool} ->
      case take(pool, c.price, []) do
        {:ok, used, pool} -> {:cont, {:ok, acc ++ [used], pool}}
        :error -> {:halt, {:error, :insufficient_funds}}
      end
    end)
    |> case do
      {:ok, per_component, _} -> {:ok, per_component}
      error -> error
    end
  end

  defp fund(_state, :simulated, _principal, budget, quote) do
    if quote.total <= budget,
      do: {:ok, Enum.map(quote.components, fn _ -> [] end)},
      else: {:error, :over_budget}
  end

  defp take(pool, 0, used), do: {:ok, Enum.reverse(used), pool}
  defp take([], _need, _used), do: :error

  defp take([{id, source, free} | rest], need, used) do
    amount = min(free, need)
    pool = if free > amount, do: [{id, source, free - amount} | rest], else: rest
    take(pool, need - amount, [%{slice_id: id, amount: amount} | used])
  end

  defp reserve_components(batches, components, funding, now, entity_id) do
    components
    |> Enum.zip(funding)
    |> Enum.reduce_while({:ok, [], batches}, fn {c, slices}, {:ok, acc, batches} ->
      case reserve_lines(batches, c.lines, now) do
        {:ok, claims} ->
          order =
            c
            |> Map.take([
              :kind,
              :recipe_id,
              :recipe_version,
              :price,
              :lines,
              :penalty,
              :quality,
              :carbs_mg,
              :prep_ms,
              :finish_ms
            ])
            |> Map.merge(%{order_id: "O:#{entity_id}:#{c.kind}", reservations: claims, funding: slices})

          {:cont, {:ok, acc ++ [order], Inventory.adjust_reserved(batches, claims, 1)}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, orders, _} -> {:ok, orders}
      error -> error
    end
  end

  # Reserve consolidated demand per product so one order holds at most one
  # claim per batch.
  defp reserve_lines(batches, lines, now) do
    lines
    |> Substitution.demand()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, [], batches}, fn {product, qty}, {:ok, acc, batches} ->
      case Inventory.plan_reservation(batches, product, qty, now) do
        {:ok, claims} -> {:cont, {:ok, acc ++ claims, Inventory.adjust_reserved(batches, claims, 1)}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, claims, _} -> {:ok, claims}
      error -> error
    end
  end

  defp fund_dessert(state, %{source: :guest} = visit, quote), do: fund(state, :guest, visit.principal, nil, quote)

  defp fund_dessert(_state, %{source: :simulated} = visit, quote) do
    if visit.budget_committed + quote.total <= visit.budget,
      do: {:ok, [[]]},
      else: {:error, :over_budget}
  end

  defp ensure(true, _reason), do: :ok
  defp ensure(_, reason), do: {:error, reason}

  defp id?(value), do: is_binary(value) and byte_size(value) in 1..64 and String.printable?(value)
end
