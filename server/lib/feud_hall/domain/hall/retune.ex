defmodule FeudHall.Domain.Hall.Retune do
  @moduledoc """
  The recorded rule change: replaces only the tunable values of a managed launch
  hall's catalog (see `FeudHall.Domain.Content.Tuning`) through one
  `hall_rules_retuned` event, decided for `{:retune_rules, %{tuning: tuning}}`
  from the system admin.

  The event carries the tuning (not a catalog), the content hash of the catalog
  after the change, and a wholesale stock top-up `stock: %{product_id => added}`.
  Evolution writes the tuning onto the catalog, sets the hash and adds the
  recorded top-up to market stock; it changes nothing else and never recomputes
  the top-up. Events before it therefore replay under the old values, and every
  pinned term (accepted orders, leases, drafts, computer-run restaurants already
  created) keeps what it was accepted under.

  What changes when:

    * At the retune, wholesale prices do not move for a product whose stock
      target rises. The published price is the base price scaled by the target
      at the demand floor over the current stock, so the decision scales that
      product's stock with its target: `added = ceil(stock * new / old) - stock`
      (only products with a raised target and `added > 0` appear). A product
      with no stock gets nothing; its price was already at the clamp. A product
      whose target is lowered gets no top-up and keeps its stock, so it is
      cheaper until the next midnight; an unchanged target changes nothing.
    * Arrivals and replenishment change at the next midnight, through the next
      `day_closed`. A day's arrival quotas (`demand.hour_quotas_millis`) and the
      market's replenishment are recorded per day by `day_closed`, so the day in
      progress keeps the quotas recorded at its start (its fractional remainder
      carries as usual), and the next `day_closed` computes the new day's quotas
      and the replenishment from the retuned rules and the stock it finds. Stock
      above a lowered target is never removed: replenishment only adds.
    * The computer-run planner reads its fallback and starter shifts at its next
      plan.

  A retune is refused as `:retune_unavailable` for a hall whose catalog is not
  the launch catalog, has no demand rules, or already has this tuning version or
  a newer one; and as `{:invalid_content, problems}` when the tuning or the
  resulting catalog fails validation.
  """

  alias FeudHall.Domain.{Content, Demand}
  alias FeudHall.Domain.Content.Tuning

  @spec decide(map(), term()) :: {:ok, [map()]} | {:error, term()}
  def decide(%{catalog: catalog} = state, tuning) do
    cond do
      not retunable?(catalog) ->
        {:error, :retune_unavailable}

      not newer?(catalog, tuning) ->
        {:error, :retune_unavailable}

      true ->
        with :ok <- Tuning.validate(catalog, tuning),
             retuned = Tuning.put(catalog, tuning),
             :ok <- Content.validate(retuned) do
          stock =
            top_up(state, catalog.rules.market.target_stock_per_equivalent, tuning.market.target_stock_per_equivalent)

          {:ok, [%{type: :hall_rules_retuned, tuning: tuning, content_hash: Content.hash(retuned), stock: stock}]}
        else
          {:error, problems} -> {:error, {:invalid_content, problems}}
        end
    end
  end

  @spec evolve(map(), map()) :: map()
  def evolve(state, %{type: :hall_rules_retuned} = event) do
    %{state | catalog: Tuning.put(state.catalog, event.tuning), content_hash: event.content_hash}
    |> update_in([:market, :stock], fn stock ->
      Enum.reduce(event.stock, stock, fn {product, added}, acc -> Map.update(acc, product, added, &(&1 + added)) end)
    end)
  end

  defp retunable?(catalog),
    do: match?(%{id: "launch", rules: %{market: %{}}}, catalog) and Demand.closes_days?(catalog)

  # A version that is not an integer is left to validation, which names it.
  defp newer?(catalog, %{version: version}) when is_integer(version), do: version > Tuning.of(catalog).version
  defp newer?(_catalog, _tuning), do: true

  # Scales the stock of each product whose target rises with that target, rounding up.
  defp top_up(state, old_targets, new_targets) do
    market_stock = get_in(state, [:market, :stock]) || %{}

    for {product, new} <- new_targets,
        old = Map.get(old_targets, product),
        is_integer(old) and old > 0 and new > old,
        stock = Map.get(market_stock, product, 0),
        added = div(stock * new + old - 1, old) - stock,
        added > 0,
        into: %{},
        do: {product, added}
  end
end
