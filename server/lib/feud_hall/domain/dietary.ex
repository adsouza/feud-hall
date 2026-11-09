defmodule FeudHall.Domain.Dietary do
  @moduledoc """
  Pure dietary-compatibility policy over a fully resolved ingredient bill.

  Compatibility is a hard eligibility filter applied before any preference
  scoring or reservation. It reads only versioned product facts: dish names,
  owner badges, and client claims are never evidence. Missing metadata is
  incompatible whenever a requirement needs it. Carbohydrate amounts are
  summed exactly across the whole portion and rounded up to whole milligrams
  once, after the full bill.

  Profiles are game eating requirements, not medical diagnoses.
  """

  @type requirement :: %{
          profile_id: String.t(),
          excludes: [atom()],
          carb_ceiling_mg: non_neg_integer() | nil
        }

  @doc "Builds the visit-pinned requirement bundle for an enabled profile."
  @spec requirement(map(), String.t()) :: {:ok, requirement()} | {:error, term()}
  def requirement(catalog, profile_id) do
    case Map.fetch(catalog.profiles, profile_id) do
      {:ok, %{enabled: true} = p} ->
        {:ok, %{profile_id: p.id, excludes: p.excludes, carb_ceiling_mg: p.carb_ceiling_mg}}

      {:ok, _} ->
        {:error, :profile_not_enabled}

      :error ->
        {:error, :unknown_profile}
    end
  end

  @doc """
  Carbohydrate content of a resolved portion in mg, rounded up once.
  Returns `{:error, {:missing_metadata, product}}` if any line lacks a value.
  """
  def portion_carbs(catalog, lines) do
    Enum.reduce_while(lines, {:ok, 0}, fn line, {:ok, acc} ->
      case catalog.products[line.product].carb_mg_per_kunit do
        nil -> {:halt, {:error, {:missing_metadata, line.product}}}
        per_kunit -> {:cont, {:ok, acc + line.qty * per_kunit}}
      end
    end)
    |> case do
      {:ok, scaled} -> {:ok, ceil_div(scaled, 1000)}
      error -> error
    end
  end

  @doc """
  Checks a resolved portion against a requirement. `carb_committed` is the
  visit's already reserved plus served carbohydrate total. Returns the
  portion's carbohydrate amount (needed for commitments) on success.
  """
  @spec check(map(), requirement(), [map()], non_neg_integer()) ::
          {:ok, non_neg_integer() | nil} | {:error, term()}
  def check(catalog, requirement, lines, carb_committed) do
    with :ok <- check_origins(catalog, requirement.excludes, lines) do
      check_carbs(catalog, requirement.carb_ceiling_mg, lines, carb_committed)
    end
  end

  defp check_origins(_catalog, [], _lines), do: :ok

  defp check_origins(catalog, excludes, lines) do
    Enum.reduce_while(lines, :ok, fn line, :ok ->
      case catalog.products[line.product].origins do
        nil ->
          {:halt, {:error, {:missing_metadata, line.product}}}

        origins ->
          case Enum.find(origins, &(&1 in excludes)) do
            nil -> {:cont, :ok}
            flag -> {:halt, {:error, {:excluded_ingredient, line.product, flag}}}
          end
      end
    end)
  end

  # Without a ceiling the amount is still recorded when known, so later
  # reporting does not depend on current content.
  defp check_carbs(catalog, nil, lines, _committed) do
    case portion_carbs(catalog, lines) do
      {:ok, mg} -> {:ok, mg}
      {:error, _} -> {:ok, nil}
    end
  end

  defp check_carbs(catalog, ceiling, lines, committed) do
    with {:ok, mg} <- portion_carbs(catalog, lines) do
      if committed + mg <= ceiling, do: {:ok, mg}, else: {:error, :carbohydrate_limit}
    end
  end

  defp ceil_div(n, d), do: div(n + d - 1, d)
end
