defmodule FeudHall.Domain.Random do
  @moduledoc """
  Deterministic, pure pseudo-random numbers (splitmix64).

  The generator state is a single non-negative integer below 2^64. It lives in
  aggregate state and is recorded in events, so live execution and replay draw
  identical values. Every draw returns `{value, next_state}`; nothing here
  reads ambient randomness, clocks, or processes.
  """

  import Bitwise

  @mask 0xFFFFFFFFFFFFFFFF
  @gamma 0x9E3779B97F4A7C15
  @two_64 1 <<< 64

  @type state :: non_neg_integer()
  @type seed :: non_neg_integer()

  @doc "Creates generator state from a seed (taken modulo 2^64)."
  @spec new(seed()) :: state()
  def new(seed) when is_integer(seed) and seed >= 0, do: seed &&& @mask

  @doc "Draws a uniformly distributed unsigned 64-bit integer."
  @spec next(state()) :: {non_neg_integer(), state()}
  def next(state) when is_integer(state) and state >= 0 and state <= @mask do
    new_state = state + @gamma &&& @mask
    z = bxor(new_state, new_state >>> 30) * 0xBF58476D1CE4E5B9 &&& @mask
    z = bxor(z, z >>> 27) * 0x94D049BB133111EB &&& @mask
    {bxor(z, z >>> 31), new_state}
  end

  @doc """
  Draws an unbiased integer in `0..n-1`.

  Draws at or above the largest multiple of `n` not exceeding 2^64 are
  rejected and redrawn, so every residue is equally likely.
  """
  @spec uniform(state(), pos_integer()) :: {non_neg_integer(), state()}
  def uniform(state, n) when is_integer(n) and n > 0 do
    limit = @two_64 - rem(@two_64, n)
    draw_below(state, n, limit)
  end

  defp draw_below(state, n, limit) do
    {value, state} = next(state)
    if value < limit, do: {rem(value, n), state}, else: draw_below(state, n, limit)
  end

  @doc "Draws an integer in `lo..hi`, inclusive on both ends."
  @spec range(state(), integer(), integer()) :: {integer(), state()}
  def range(state, lo, hi) when is_integer(lo) and is_integer(hi) and lo <= hi do
    {offset, state} = uniform(state, hi - lo + 1)
    {lo + offset, state}
  end

  @doc """
  Picks a key with probability proportional to its integer weight.

  Keys keep the order given; the weights must sum to a positive total. Keys
  with weight 0 are never chosen.
  """
  @spec weighted(state(), [{key, non_neg_integer()}, ...]) :: {key, state()} when key: term()
  def weighted(state, [_ | _] = entries) do
    total = weight_total(entries, 0)
    total > 0 or raise ArgumentError, "weights must sum to a positive total"
    {point, state} = uniform(state, total)
    {pick(entries, point), state}
  end

  defp weight_total([], acc), do: acc

  defp weight_total([{_key, w} | rest], acc) when is_integer(w) and w >= 0,
    do: weight_total(rest, acc + w)

  defp pick([{key, w} | rest], point) do
    if point < w, do: key, else: pick(rest, point - w)
  end

  @doc "Derives a stable sub-seed from SHA-256 of `<<seed::64, label::binary>>`."
  @spec derive(seed(), binary()) :: seed()
  def derive(seed, label) when is_integer(seed) and seed >= 0 and is_binary(label) do
    <<value::64, _::binary>> = :crypto.hash(:sha256, <<seed &&& @mask::64, label::binary>>)
    value
  end
end
