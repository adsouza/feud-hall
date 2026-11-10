defmodule FeudHall.Application.DiningHistory do
  @moduledoc "Authorized receipts derived from committed guest visit and settlement facts."

  alias FeudHall.Application.Replay
  alias FeudHall.Domain.Identity

  @page_size 20
  @max_version 9_223_372_036_854_775_807

  def page(%{state: nil}, _device, _before), do: {:error, :hall_not_initialized}

  def page(runtime, device, before) do
    with principal when is_binary(principal) <- Identity.principal_for_device(Identity.get(runtime.control), device),
         {:ok, cursor} <- cursor(before),
         true <- function_exported?(runtime.store_mod, :guest_visit_events, 6),
         {:ok, visits} <-
           runtime.store_mod.guest_visit_events(
             runtime.store,
             Replay.hall_stream(runtime.state),
             principal,
             runtime.versions.hall,
             cursor,
             @page_size + 1
           ) do
      {visible, remaining} = Enum.split(visits, @page_size)
      next = if remaining != [], do: Integer.to_string(List.last(visible).version)

      with {:ok, receipts} <- build_receipts(visible),
           do: {:ok, %{receipts: receipts, before: next}}
    else
      nil -> {:error, :unauthenticated}
      false -> {:error, :history_unavailable}
      {:error, _} = error -> error
    end
  end

  defp cursor(nil), do: {:ok, @max_version}

  defp cursor(value) when is_binary(value) and byte_size(value) <= 19 do
    case Integer.parse(value) do
      {version, ""} when version > 0 and version <= @max_version -> {:ok, version}
      _ -> {:error, :invalid_history_cursor}
    end
  end

  defp cursor(_), do: {:error, :invalid_history_cursor}

  defp build_receipts(visits) do
    Enum.reduce_while(Enum.reverse(visits), {:ok, []}, fn visit, {:ok, acc} ->
      case receipt(visit) do
        {:ok, row} -> {:cont, {:ok, [row | acc]}}
        error -> {:halt, error}
      end
    end)
  end

  defp receipt(%{admitted: admitted, finalized: finalized, at: at, orders: accepted}) do
    orders = Map.new(accepted, &{&1.order_id, &1})

    with {:ok, courses, total} <- charge_courses(finalized.components, orders) do
      {:ok,
       %{
         visit_id: admitted.visit_id,
         restaurant_id: admitted.restaurant_id,
         stall_id: admitted.stall_id,
         at: at,
         reason: finalized.reason,
         courses: courses,
         total: Integer.to_string(total)
       }}
    end
  end

  defp charge_courses(components, orders) do
    Enum.reduce_while(Enum.reverse(components), {:ok, [], 0}, fn component, {:ok, courses, total} ->
      case Map.get(orders, component.order_id) do
        %{price: price, kind: kind, recipe_id: recipe} ->
          charge = if component.outcome == :served, do: price, else: 0

          course = %{
            kind: kind,
            recipe_id: recipe,
            outcome: component.outcome,
            price: Integer.to_string(price),
            charged: Integer.to_string(charge)
          }

          {:cont, {:ok, [course | courses], total + charge}}

        nil ->
          {:halt, {:error, :history_unavailable}}
      end
    end)
  end
end
