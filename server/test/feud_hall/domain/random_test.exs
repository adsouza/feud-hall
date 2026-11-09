defmodule FeudHall.Domain.RandomTest do
  use ExUnit.Case, async: true

  alias FeudHall.Domain.Random

  @max_u64 0xFFFFFFFFFFFFFFFF

  defp draws(state, count, fun) do
    {values, _state} =
      Enum.map_reduce(1..count, state, fn _, acc -> fun.(acc) end)

    values
  end

  describe "next/1" do
    test "matches the reference splitmix64 first output for seed 0" do
      assert {16_294_208_416_658_607_535, _state} = Random.new(0) |> Random.next()
    end

    test "state and outputs stay within 64 bits" do
      state = Random.new(@max_u64)
      assert state <= @max_u64

      {values, final} =
        Enum.map_reduce(1..100, state, fn _, acc -> Random.next(acc) end)

      assert Enum.all?(values, &(&1 in 0..@max_u64))
      assert final in 0..@max_u64
    end

    test "identical seeds give identical sequences and different seeds differ" do
      a = draws(Random.new(42), 50, &Random.next/1)
      b = draws(Random.new(42), 50, &Random.next/1)
      c = draws(Random.new(43), 50, &Random.next/1)

      assert a == b
      refute a == c
    end

    test "a persisted state resumes the same sequence" do
      {_, mid} = Random.new(9) |> Random.next()
      {_, mid} = Random.next(mid)
      assert draws(mid, 10, &Random.next/1) == draws(mid, 10, &Random.next/1)
    end
  end

  describe "uniform/2" do
    test "never returns n and is uniform within 5% per bucket for n = 7" do
      counts =
        Random.new(2026)
        |> draws(30_000, &Random.uniform(&1, 7))
        |> Enum.frequencies()

      assert Map.keys(counts) |> Enum.sort() == Enum.to_list(0..6)

      expected = div(30_000, 7)

      for {_bucket, count} <- counts do
        assert abs(count - expected) * 100 <= expected * 5
      end
    end

    test "n = 1 always returns 0" do
      assert Random.new(5) |> draws(20, &Random.uniform(&1, 1)) |> Enum.uniq() == [0]
    end

    test "handles n above 2^63 by rejecting biased draws" do
      n = 0x8000000000000001
      values = Random.new(77) |> draws(200, &Random.uniform(&1, n))
      assert Enum.all?(values, &(&1 in 0..(n - 1)))
    end

    test "rejects non-positive n" do
      assert_raise FunctionClauseError, fn -> Random.uniform(Random.new(1), 0) end
    end
  end

  describe "range/3" do
    test "is inclusive on both ends" do
      values = Random.new(3) |> draws(500, &Random.range(&1, -2, 2))
      assert Enum.sort(Enum.uniq(values)) == [-2, -1, 0, 1, 2]
    end

    test "lo = hi returns lo" do
      assert {4, _} = Random.range(Random.new(3), 4, 4)
    end

    test "rejects lo > hi" do
      assert_raise FunctionClauseError, fn -> Random.range(Random.new(3), 5, 4) end
    end
  end

  describe "weighted/2" do
    test "never returns a zero-weight key and hits [a: 1, b: 3] in ratio within 5%" do
      counts =
        Random.new(11)
        |> draws(20_000, &Random.weighted(&1, a: 1, b: 3, never: 0))
        |> Enum.frequencies()

      refute Map.has_key?(counts, :never)
      assert counts.a + counts.b == 20_000
      assert abs(counts.a - 5_000) * 100 <= 5_000 * 5
      assert abs(counts.b - 15_000) * 100 <= 15_000 * 5
    end

    test "a single positive weight always wins, wherever it sits" do
      values = Random.new(8) |> draws(50, &Random.weighted(&1, [{:x, 0}, {:y, 2}, {:z, 0}]))
      assert Enum.uniq(values) == [:y]
    end

    test "rejects an empty list and a zero total" do
      assert_raise FunctionClauseError, fn -> Random.weighted(Random.new(1), []) end
      assert_raise ArgumentError, fn -> Random.weighted(Random.new(1), a: 0, b: 0) end
    end
  end

  describe "derive/2" do
    test "is stable and label-sensitive" do
      assert Random.derive(1, "demand") == Random.derive(1, "demand")
      assert Random.derive(1, "demand") != Random.derive(1, "npc:budget")
      assert Random.derive(1, "demand") != Random.derive(2, "demand")
    end

    test "returns a 64-bit seed matching SHA-256 of seed and label" do
      <<expected::64, _::binary>> = :crypto.hash(:sha256, <<1::64, "demand">>)
      assert Random.derive(1, "demand") == expected
    end
  end
end
