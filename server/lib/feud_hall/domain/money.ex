defmodule FeudHall.Domain.Money do
  @moduledoc """
  Bounded exact currency amounts in integer smallest units (cents).

  Money is a plain integer inside the domain so arithmetic stays exact and
  cheap; this module owns the bounds and the canonical decimal-string codec
  used wherever an amount crosses a JSON/TypeScript boundary.
  """

  # 10^18 cents fits a PostgreSQL bigint and deliberately exceeds JavaScript's
  # exact-integer range (2^53 - 1), so every client path must use strings.
  @max 1_000_000_000_000_000_000

  @type t :: integer()

  @spec max() :: pos_integer()
  def max, do: @max

  @doc "True when `amount` is an integer within the signed domain bounds."
  @spec valid?(term()) :: boolean()
  def valid?(amount), do: is_integer(amount) and amount >= -@max and amount <= @max

  @doc "True when `amount` is a valid non-negative amount."
  @spec non_negative?(term()) :: boolean()
  def non_negative?(amount), do: valid?(amount) and amount >= 0

  @doc "Encodes an amount as a canonical decimal integer string."
  @spec to_canonical(t()) :: String.t()
  def to_canonical(amount) when is_integer(amount), do: Integer.to_string(amount)

  @doc """
  Parses a canonical decimal integer string: optional `-`, no leading zeros,
  no `+`, whitespace, fraction, or exponent. Rejects out-of-bound values.
  """
  @spec parse(term()) :: {:ok, t()} | {:error, :invalid_money}
  def parse(value) when is_binary(value) and byte_size(value) <= 20 do
    if Regex.match?(~r/\A(0|-?[1-9][0-9]*)\z/, value) do
      amount = String.to_integer(value)
      if valid?(amount), do: {:ok, amount}, else: {:error, :invalid_money}
    else
      {:error, :invalid_money}
    end
  end

  def parse(_), do: {:error, :invalid_money}

  @doc """
  Exact proportional share `total * part / whole`, rounded down.

  Callers that must conserve a total take the remainder on the final share
  rather than rounding every share independently.
  """
  @spec prorate(non_neg_integer(), non_neg_integer(), pos_integer()) :: non_neg_integer()
  def prorate(total, part, whole) when whole > 0 and part <= whole, do: div(total * part, whole)

  @doc "Integer ceiling division for non-negative numerators."
  @spec ceil_div(non_neg_integer(), pos_integer()) :: non_neg_integer()
  def ceil_div(n, d) when n >= 0 and d > 0, do: div(n + d - 1, d)
end
