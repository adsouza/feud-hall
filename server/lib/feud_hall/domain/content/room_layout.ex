defmodule FeudHall.Domain.Content.RoomLayout do
  @moduledoc """
  Assigns each spot of a 150-spot layout to one of ten rooms of fifteen positions.

  Positions run clockwise from the north-west corner: 0, 6, 9 and 12 are corners (quiet), 1 to 5 the
  north wall (standard), 7 and 8 the east wall and 13 and 14 the west wall (busy), 10 and 11 the south
  wall (prime). Odd rooms hold a standard spot at 13 and a prime spot at 11; even rooms hold a busy spot
  at 13 and a standard spot at 11. Within a class, ascending spot order fills rooms and then positions in
  order. Pure data: a spot's room and position never change and its tier is untouched.
  """

  @rooms 10
  @per_room 15

  @doc "The class a position holds in a room."
  @spec kind(pos_integer(), 0..14) :: :quiet | :standard | :busy | :prime
  def kind(_room, position) when position in [0, 6, 9, 12], do: :quiet
  def kind(_room, position) when position in 1..5, do: :standard
  def kind(_room, position) when position in [7, 8, 14], do: :busy
  def kind(_room, 10), do: :prime
  def kind(room, 11), do: if(rem(room, 2) == 1, do: :prime, else: :standard)
  def kind(room, 13), do: if(rem(room, 2) == 1, do: :standard, else: :busy)

  @doc "Adds `room` (1..10) and `position` (0..14) to every spot of a layout."
  @spec assign([%{slot_id: String.t(), tier: atom()}]) :: [map()]
  def assign(layout) do
    cells =
      for room <- 1..@rooms, position <- 0..(@per_room - 1), do: {kind(room, position), room, position}

    queues = Enum.group_by(cells, &elem(&1, 0), fn {_, room, position} -> {room, position} end)

    {assigned, _} =
      Enum.map_reduce(layout, queues, fn spot, queues ->
        case Map.get(queues, spot.tier, []) do
          [{room, position} | rest] ->
            {Map.merge(spot, %{room: room, position: position}), Map.put(queues, spot.tier, rest)}

          [] ->
            raise ArgumentError, "no free room position for #{spot.slot_id} (#{inspect(spot.tier)})"
        end
      end)

    assigned
  end
end
