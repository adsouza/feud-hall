defmodule FeudHall.Domain.Hall.Rooms do
  @moduledoc """
  The room rule: which rooms of the hall are open, and what each quality class
  currently costs to lease. Everything is derived from committed state; nothing
  here is stored or written.

  A room is open when it, or any later room, holds a lease or a draft
  reservation, or when every spot of at least one class in the rooms before it
  is leased. Drafts never count as leased. Halls whose catalog carries no
  `rules.rooms` (the slice catalog) have no rooms: every spot is open and rents
  are the base rents.
  """

  alias FeudHall.Domain.Hall.Management

  @tiers [:quiet, :standard, :busy, :prime]

  @type tier :: :quiet | :standard | :busy | :prime
  @type class_quote :: %{
          leased: non_neg_integer(),
          total: non_neg_integer(),
          base_rent: integer(),
          rent: integer(),
          holding: integer()
        }
  @type spot :: %{room: pos_integer() | nil, position: non_neg_integer() | nil}
  @type summary :: %{
          open: non_neg_integer(),
          count: non_neg_integer(),
          classes: %{tier => class_quote},
          spots: %{String.t() => spot}
        }

  @doc "True when the pinned catalog carries a room rule."
  @spec enabled?(map()) :: boolean()
  def enabled?(state), do: is_map(rule(state))

  @doc "The room of a spot, or nil when the catalog has no room data for it."
  @spec room(map(), String.t()) :: pos_integer() | nil
  def room(state, slot_id) do
    Enum.find_value(state.catalog.layout, fn entry -> entry.slot_id == slot_id && Map.get(entry, :room) end)
  end

  @doc """
  Open rooms, the current quote of every class, and each spot's room and
  position (nil without room data), from committed state.
  """
  @spec summary(map()) :: summary()
  def summary(state) do
    layout = state.catalog.layout
    rates = lease_rates(state)
    spots = Map.new(layout, &{&1.slot_id, %{room: Map.get(&1, :room), position: Map.get(&1, :position)}})

    case rule(state) do
      nil ->
        classes = classes(layout, state, rates, nil, nil)
        %{open: 0, count: 0, classes: classes, spots: spots}

      rooms_rule ->
        count = rooms_rule.count
        open = open_rooms(state, layout, count)
        classes = classes(layout, state, rates, rooms_rule, open)
        %{open: open, count: count, classes: classes, spots: spots}
    end
  end

  @doc """
  True when the spot may be reserved, leased or offered. Pass a summary already
  computed from the same state to avoid recomputing it.
  """
  @spec open?(map(), String.t(), summary() | nil) :: boolean()
  def open?(state, slot_id, summary \\ nil) do
    if enabled?(state) do
      summary = summary || summary(state)
      # A spot with no catalog room counts as open: callers check that the spot exists first.
      (get_in(summary.spots, [slot_id, :room]) || 0) <= summary.open
    else
      true
    end
  end

  @doc "The quote for one class."
  @spec quote(summary(), tier()) :: %{
          rent: integer(),
          holding: integer(),
          base_rent: integer(),
          leased: non_neg_integer(),
          total: non_neg_integer()
        }
  def quote(summary, tier) do
    Map.fetch!(summary.classes, tier)
  end

  defp rule(state) do
    case state.catalog.rules[:rooms] do
      rooms when is_map(rooms) -> rooms
      _ -> nil
    end
  end

  defp lease_rates(state) do
    case state do
      %{management: %{rules: %{lease_rates: rates}}} -> rates
      _ -> Management.rules().lease_rates
    end
  end

  defp leased?(state, slot_id), do: Map.has_key?(state.stalls, slot_id)

  defp drafted_ids(state) do
    case state do
      %{management: %{draft_by_stall: drafts}} when is_map(drafts) -> Map.keys(drafts)
      _ -> []
    end
  end

  defp open_rooms(state, layout, count) do
    room_of = Map.new(layout, &{&1.slot_id, &1.room})
    held = Enum.filter(Map.keys(state.stalls) ++ drafted_ids(state), &Map.has_key?(room_of, &1))
    start = max(1, held |> Enum.map(&room_of[&1]) |> Enum.max(fn -> 1 end))

    # Per room and class: {spots, leased spots}.
    tallies =
      Enum.reduce(layout, %{}, fn entry, acc ->
        leased = if leased?(state, entry.slot_id), do: 1, else: 0

        Map.update(acc, {entry.room, entry.tier}, {1, leased}, fn {total, got} -> {total + 1, got + leased} end)
      end)

    widen(start, count, tallies)
  end

  defp widen(open, count, _tallies) when open >= count, do: open

  defp widen(open, count, tallies) do
    if class_full?(tallies, open), do: widen(open + 1, count, tallies), else: open
  end

  defp class_full?(tallies, open) do
    Enum.any?(@tiers, fn tier ->
      {total, leased} = within(tallies, tier, open)
      total > 0 and total == leased
    end)
  end

  defp within(tallies, tier, open) do
    Enum.reduce(1..open//1, {0, 0}, fn room, {total, leased} ->
      {t, l} = Map.get(tallies, {room, tier}, {0, 0})
      {total + t, leased + l}
    end)
  end

  defp classes(layout, state, rates, rooms_rule, open) do
    counted =
      Enum.filter(layout, fn entry -> is_nil(open) or entry.room <= open end)

    tallies =
      Enum.reduce(counted, %{}, fn entry, acc ->
        leased = if leased?(state, entry.slot_id), do: 1, else: 0
        Map.update(acc, entry.tier, {1, leased}, fn {total, got} -> {total + 1, got + leased} end)
      end)

    cap = rooms_rule && rooms_rule.scarcity_cap_permille
    gap = rooms_rule && rooms_rule.class_gap

    @tiers
    |> Enum.reverse()
    |> Enum.reduce({%{}, nil}, fn tier, {acc, above} ->
      [base_rent, base_holding] = Map.fetch!(rates, tier)
      {total, leased} = Map.get(tallies, tier, {0, 0})

      rent =
        if rooms_rule do
          raw = raw_rent(base_rent, cap, total, leased)
          if above, do: min(raw, above - gap), else: raw
        else
          base_rent
        end

      entry = %{
        leased: leased,
        total: total,
        base_rent: base_rent,
        rent: rent,
        holding: div(base_holding * rent, base_rent)
      }

      {Map.put(acc, tier, entry), rent}
    end)
    |> elem(0)
  end

  defp raw_rent(base, cap, total, leased) when total <= 1 or leased >= total - 1, do: div(base * cap, 1000)

  defp raw_rent(base, cap, total, leased) do
    div(base * (1000 * (total - 1) + (cap - 1000) * leased), 1000 * (total - 1))
  end
end
