defmodule FeudHall.Domain.Hall.Retune do
  @moduledoc """
  The recorded rule change: replaces only the tunable values of a managed launch
  hall's catalog (see `FeudHall.Domain.Content.Tuning`) through one
  `hall_rules_retuned` event, decided for `{:retune_rules, %{tuning: tuning}}`
  from the system admin.

  The event carries the tuning, not a catalog, and the content hash of the
  catalog after the change. Evolution writes the tuning onto the catalog and
  sets the hash; it changes nothing else. Events before it therefore replay
  under the old values, and every pinned term (accepted orders, leases, drafts,
  computer-run restaurants already created) keeps what it was accepted under.

  When the values take effect:

    * Arrivals and wholesale replenishment change at the next midnight, through
      the next `day_closed`. A day's arrival quotas (`demand.hour_quotas_millis`)
      and the market's replenishment are recorded per day by `day_closed`, so
      the day in progress keeps the quotas recorded at its start (its fractional
      remainder carries as usual), and the next `day_closed` computes the new
      day's quotas and the replenishment from the retuned rules. Stock above a
      lowered target is never removed: replenishment only adds.
    * Values read where they are used, not recorded per day, apply from their next
      use: the published wholesale price reads the stock target at the next
      quote or clearing, and the computer-run planner reads its fallback and
      starter shifts at its next plan.

  A retune is refused as `:retune_unavailable` for a hall whose catalog is not
  the launch catalog, has no demand rules, or already has this tuning version or
  a newer one; and as `{:invalid_content, problems}` when the tuning or the
  resulting catalog fails validation.
  """

  alias FeudHall.Domain.{Content, Demand}
  alias FeudHall.Domain.Content.Tuning

  @spec decide(map(), term()) :: {:ok, [map()]} | {:error, term()}
  def decide(%{catalog: catalog}, tuning) do
    cond do
      not retunable?(catalog) ->
        {:error, :retune_unavailable}

      not newer?(catalog, tuning) ->
        {:error, :retune_unavailable}

      true ->
        with :ok <- Tuning.validate(catalog, tuning),
             retuned = Tuning.put(catalog, tuning),
             :ok <- Content.validate(retuned) do
          {:ok, [%{type: :hall_rules_retuned, tuning: tuning, content_hash: Content.hash(retuned)}]}
        else
          {:error, problems} -> {:error, {:invalid_content, problems}}
        end
    end
  end

  @spec evolve(map(), map()) :: map()
  def evolve(state, %{type: :hall_rules_retuned} = event),
    do: %{state | catalog: Tuning.put(state.catalog, event.tuning), content_hash: event.content_hash}

  defp retunable?(catalog),
    do: match?(%{id: "launch", rules: %{market: %{}}}, catalog) and Demand.closes_days?(catalog)

  # A version that is not an integer is left to validation, which names it.
  defp newer?(catalog, %{version: version}) when is_integer(version), do: version > Tuning.of(catalog).version
  defp newer?(_catalog, _tuning), do: true
end
