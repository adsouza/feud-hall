defmodule FeudHall.Domain.Substitution do
  @moduledoc """
  Resolves a recipe's ingredient bill under the owner's per-line substitution
  policies against shared warehouse availability.

  Policies per line: `:primary_only` (default), `:prefer_primary` (allow the
  approved substitute as fallback), and `:prefer_substitute`. Each line uses
  exactly one product. Resolution considers the *whole* bill: candidate
  combinations are tried in preference order (earlier lines vary slowest) and
  the first whose consolidated demand fits availability wins. Several lines,
  and the other components of a tray, may draw on the same product, so demand
  is always summed per product before comparing. Substitute quantities use the
  approved conversion, rounded up.
  """

  @policies [:primary_only, :prefer_primary, :prefer_substitute]

  def policies, do: @policies

  @doc """
  Returns `{:ok, %{lines: resolved, penalty: p}}` or `{:error, :unavailable}`.

  `available` maps product ids to units still free for this bill (callers
  subtract demand already planned for other tray components).
  """
  def resolve(catalog, recipe, policies, available) do
    options = Enum.map(recipe.lines, &line_options(&1, Map.get(policies, &1.line_id, :primary_only)))

    options
    |> combinations()
    |> Enum.find(&fits?(&1, available))
    |> case do
      nil ->
        {:error, :unavailable}

      lines ->
        penalty =
          lines
          |> Enum.map(& &1.penalty)
          |> Enum.sum()
          |> min(catalog.rules.substitution_penalty_cap)

        {:ok, %{lines: lines, penalty: penalty}}
    end
  end

  @doc "Consolidated demand per product for resolved lines."
  def demand(lines) do
    Enum.reduce(lines, %{}, fn l, acc -> Map.update(acc, l.product, l.qty, &(&1 + l.qty)) end)
  end

  @doc "Subtracts a demand map from availability."
  def subtract(available, demand) do
    Enum.reduce(demand, available, fn {p, q}, acc -> Map.update(acc, p, -q, &(&1 - q)) end)
  end

  @doc "Quality of a resolved variant on the normalized 100-point scale."
  def quality(catalog, penalty), do: max(catalog.rules.quality_base - penalty, 0)

  defp line_options(line, policy) do
    primary = %{line_id: line.line_id, product: line.product, qty: line.qty, substituted: false, penalty: 0}

    case {line.substitute, policy} do
      {nil, _} -> [primary]
      {_, :primary_only} -> [primary]
      {sub, :prefer_primary} -> [primary, substitute(line, sub)]
      {sub, :prefer_substitute} -> [substitute(line, sub), primary]
    end
  end

  defp substitute(line, sub) do
    %{
      line_id: line.line_id,
      product: sub.product,
      qty: div(line.qty * sub.num + sub.den - 1, sub.den),
      substituted: true,
      penalty: sub.penalty
    }
  end

  defp combinations([]), do: [[]]

  defp combinations([options | rest]) do
    tails = combinations(rest)
    for option <- options, tail <- tails, do: [option | tail]
  end

  defp fits?(lines, available) do
    lines |> demand() |> Enum.all?(fn {p, q} -> Map.get(available, p, 0) >= q end)
  end
end
