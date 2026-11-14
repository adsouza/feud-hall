defmodule FeudHall.Domain.RoomLayoutTest do
  use ExUnit.Case, async: true

  alias FeudHall.Domain.Content.{RoomLayout, SliceCatalog}

  @layout SliceCatalog.catalog().layout
  @assigned RoomLayout.assign(@layout)

  defp ids(room, tier),
    do: for(s <- @assigned, s.room == room, s.tier == tier, do: s.slot_id)

  defp positions(room), do: for(s <- @assigned, s.room == room, into: %{}, do: {s.slot_id, s.position})

  test "each room holds its stated mix" do
    for room <- 1..10 do
      mix = for(s <- @assigned, s.room == room, do: s.tier) |> Enum.frequencies()

      expected =
        if rem(room, 2) == 1,
          do: %{quiet: 4, standard: 6, busy: 3, prime: 2},
          else: %{quiet: 4, standard: 6, busy: 4, prime: 1}

      assert mix == expected, "room #{room}"
    end
  end

  test "room 1 holds the lowest IDs of every class" do
    room_1 = for s <- @assigned, s.room == 1, do: s.slot_id

    expected =
      Enum.map(1..4, &spot/1) ++
        Enum.map(41..46, &spot/1) ++ Enum.map(101..103, &spot/1) ++ [spot(136), spot(137)]

    assert Enum.sort(room_1) == Enum.sort(expected)
  end

  test "every spot has a distinct room and position" do
    pairs = for s <- @assigned, do: {s.room, s.position}
    assert length(pairs) == 150
    assert pairs |> Enum.uniq() |> length() == 150
    assert Enum.all?(pairs, fn {room, position} -> room in 1..10 and position in 0..14 end)
  end

  test "a spot's class is the class of its position" do
    for s <- @assigned, do: assert(s.tier == RoomLayout.kind(s.room, s.position))
    assert RoomLayout.kind(1, 13) == :standard
    assert RoomLayout.kind(2, 13) == :busy
    assert RoomLayout.kind(1, 11) == :prime
    assert RoomLayout.kind(2, 11) == :standard
  end

  test "within a room a class fills its positions in ascending order" do
    one = positions(1)

    assert [{"s001", 0}, {"s002", 6}, {"s003", 9}, {"s004", 12}] ==
             for(id <- ids(1, :quiet), do: {id, one[id]})

    assert Map.take(one, Enum.map(41..45, &spot/1)) == Map.new(Enum.zip(Enum.map(41..45, &spot/1), 1..5))
    assert one["s046"] == 13
    assert {one["s101"], one["s102"], one["s103"]} == {7, 8, 14}
    assert {one["s136"], one["s137"]} == {10, 11}

    two = positions(2)
    assert Map.take(two, Enum.map(47..51, &spot/1)) == Map.new(Enum.zip(Enum.map(47..51, &spot/1), 1..5))
    assert two["s052"] == 11
    assert {two["s104"], two["s105"], two["s106"], two["s107"]} == {7, 8, 13, 14}
    assert two["s138"] == 10
  end

  test "tiers are untouched" do
    assert Enum.map(@assigned, &{&1.slot_id, &1.tier}) == Enum.map(@layout, &{&1.slot_id, &1.tier})
  end

  defp spot(n), do: "s" <> String.pad_leading(Integer.to_string(n), 3, "0")
end
