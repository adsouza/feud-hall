defmodule FeudHall.Domain.RoomsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias FeudHall.Domain.Content.{LaunchCatalog, SliceCatalog}
  alias FeudHall.Domain.Hall.{Management, Rooms}

  @catalog LaunchCatalog.catalog()
  @all_ids Enum.map(@catalog.layout, & &1.slot_id)
  @tiers [:quiet, :standard, :busy, :prime]

  defp ids(from, to), do: for(n <- from..to, do: "s" <> String.pad_leading(Integer.to_string(n), 3, "0"))

  defp state(leased, drafted \\ [], catalog \\ @catalog) do
    %{
      catalog: catalog,
      stalls: Map.new(leased, &{&1, %{}}),
      management: %{draft_by_stall: Map.new(drafted, &{&1, %{}}), rules: Management.rules()}
    }
  end

  defp rents(state), do: Map.new(@tiers, &{&1, Rooms.quote(Rooms.summary(state), &1).rent})

  describe "open rooms" do
    test "room 1 is open in an empty hall" do
      summary = Rooms.summary(state([]))
      assert summary.open == 1
      assert summary.count == 10
    end

    test "the last spot of a class opens the next room" do
      assert Rooms.summary(state(["s136"])).open == 1
      assert Rooms.summary(state(["s136", "s137"])).open == 2
    end

    test "a draft does not count as leased" do
      assert Rooms.summary(state(["s136"], ["s137"])).open == 1
    end

    test "a surrender that reopens a class closes an empty next room" do
      assert Rooms.summary(state(["s136", "s137"])).open == 2
      assert Rooms.summary(state(["s136"])).open == 1
    end

    test "a lease or draft keeps its room and every earlier room open" do
      assert Rooms.summary(state(["s009"])).open == 3
      assert Rooms.summary(state([], ["s005"])).open == 2
    end

    test "rooms open in a chain" do
      assert Rooms.summary(state(ids(1, 8))).open == 3
    end

    test "all ten rooms can open and no more" do
      assert Rooms.summary(state(@all_ids)).open == 10
    end

    test "open?/3 follows the summary and works with or without one" do
      state = state(["s136", "s137"])
      summary = Rooms.summary(state)
      assert Rooms.open?(state, "s138", summary)
      assert Rooms.open?(state, "s138")
      refute Rooms.open?(state, "s009", summary)
      refute Rooms.open?(state, "s009")
      assert Rooms.room(state, "s009") == 3
      assert Rooms.room(state, "nope") == nil
    end
  end

  describe "rent quotes" do
    test "an empty hall quotes the base rents" do
      assert rents(state([])) == %{quiet: 8_000, standard: 10_000, busy: 15_000, prime: 22_000}
    end

    test "rent rises as a class fills" do
      assert Rooms.quote(Rooms.summary(state(["s001"])), :quiet).rent == 9_333
      assert Rooms.quote(Rooms.summary(state(["s041", "s042"])), :standard).rent == 12_000
    end

    test "the last spot of a class costs the cap, and holding scales with rent" do
      quote = Rooms.quote(Rooms.summary(state(["s136"])), :prime)
      assert quote.rent == 33_000
      assert quote.holding == 3_300
      assert quote.base_rent == 22_000
      assert {quote.leased, quote.total} == {1, 2}
    end

    test "a class is held a gap below the class above it" do
      quote = Rooms.quote(Rooms.summary(state(["s001", "s002", "s003"])), :quiet)
      assert quote.rent == 9_900
      assert quote.holding == 990
    end

    test "a room opening lowers new quotes" do
      state = state(ids(41, 46))
      assert Rooms.summary(state).open == 2
      assert Rooms.quote(Rooms.summary(state), :standard).rent == 12_727
    end

    test "a draft in a later room counts its room's spots toward totals" do
      quote = Rooms.quote(Rooms.summary(state([], ["s005"])), :quiet)
      assert {quote.leased, quote.total} == {0, 8}
    end

    test "an unmanaged hall uses the base rates and has no drafts" do
      state = Map.delete(state([]), :management)
      assert rents(state) == %{quiet: 8_000, standard: 10_000, busy: 15_000, prime: 22_000}
    end
  end

  describe "a catalog without a room rule" do
    test "base rents and every spot open" do
      slice = SliceCatalog.catalog()
      state = state(["s001"], [], slice)
      refute Rooms.enabled?(state)
      assert Rooms.enabled?(state([]))

      summary = Rooms.summary(state)
      assert %{open: 0, count: 0} = summary
      assert rents(state) == %{quiet: 8_000, standard: 10_000, busy: 15_000, prime: 22_000}
      assert Rooms.quote(summary, :quiet).holding == 800
      assert Rooms.quote(summary, :quiet).leased == 1
      assert Rooms.quote(summary, :quiet).total == Enum.count(slice.layout, &(&1.tier == :quiet))
      assert Enum.all?(slice.layout, &Rooms.open?(state, &1.slot_id, summary))
      assert Rooms.open?(state, "anything")
      assert Rooms.room(state, "s001") == nil
    end
  end

  # Either a random scatter of leases at some density, or whole rooms filled from room 1
  # (so that classes complete and rooms open), then a few spots drafted.
  defp holdings do
    scatter =
      gen all(
            density <- member_of([3, 10, 30, 60, 90]),
            rolls <- list_of(integer(0..99), length: length(@all_ids))
          ) do
        {Enum.zip(@all_ids, rolls), fn roll -> roll < density end}
      end

    filled =
      gen all(
            rooms <- integer(0..10),
            rolls <- list_of(integer(0..99), length: length(@all_ids))
          ) do
        in_room = Map.new(@catalog.layout, &{&1.slot_id, &1.room})
        {Enum.zip(@all_ids, rolls), nil, rooms, in_room}
      end

    bind(one_of([scatter, filled]), fn
      {pairs, test} ->
        constant(split(pairs, fn {_id, roll} -> test.(roll) end))

      {pairs, nil, rooms, in_room} ->
        constant(split(pairs, fn {id, roll} -> in_room[id] <= rooms and roll < 95 end))
    end)
  end

  defp split(pairs, leased?) do
    {leased, rest} = Enum.split_with(pairs, leased?)
    drafted = for {id, roll} <- rest, roll >= 96, do: id
    {Enum.map(leased, &elem(&1, 0)), drafted}
  end

  describe "properties" do
    property "open rooms are a prefix that covers every lease and draft" do
      check all({leased, drafted} <- holdings(), max_runs: 200) do
        state = state(leased, drafted)
        open = Rooms.summary(state).open
        assert open in 1..10
        assert Enum.all?(leased ++ drafted, &(Rooms.room(state, &1) <= open))
      end
    end

    property "class order is preserved" do
      check all({leased, drafted} <- holdings(), max_runs: 200) do
        rents = rents(state(leased, drafted))
        assert rents.quiet < rents.standard
        assert rents.standard < rents.busy
        assert rents.busy < rents.prime
      end
    end

    property "within fixed open rooms a class's quote never falls as it fills" do
      {:ok, counter} = Agent.start_link(fn -> {0, 0} end)

      check all({leased, drafted} <- holdings(), max_runs: 200) do
        before_state = state(leased, drafted)
        before = Rooms.summary(before_state)

        vacant =
          Enum.filter(@catalog.layout, fn entry ->
            entry.slot_id not in leased and entry.slot_id not in drafted and entry.room <= before.open
          end)

        if vacant != [] do
          pick = Enum.at(vacant, rem(:erlang.phash2({leased, drafted}), length(vacant)))
          after_summary = Rooms.summary(state([pick.slot_id | leased], drafted))
          same? = after_summary.open == before.open
          Agent.update(counter, fn {runs, kept} -> {runs + 1, if(same?, do: kept + 1, else: kept)} end)

          if same? do
            assert Rooms.quote(after_summary, pick.tier).rent >= Rooms.quote(before, pick.tier).rent
          end
        end
      end

      {runs, kept} = Agent.get(counter, & &1)
      assert runs > 0
      assert kept * 5 >= runs, "only #{kept} of #{runs} runs kept the open rooms unchanged"
    end

    property "rent stays between base and the cap, except where the gap holds it lower" do
      check all({leased, drafted} <- holdings(), max_runs: 200) do
        summary = Rooms.summary(state(leased, drafted))

        @tiers
        |> Enum.reverse()
        |> Enum.reduce(nil, fn tier, above ->
          quote = Rooms.quote(summary, tier)
          assert quote.rent <= div(quote.base_rent * 1500, 1000)
          floor = if above, do: min(quote.base_rent, above - 100), else: quote.base_rent
          assert quote.rent >= floor
          quote.rent
        end)
      end
    end
  end
end
