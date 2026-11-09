defmodule FeudHall.Application.EventStore do
  @moduledoc """
  Application-owned event-store port.

  Adapters must append a complete batch and its immutable receipt atomically
  against an expected global position (optimistic concurrency), return
  complete committed batches in order, and look up receipts by command ID.
  An append may report `{:error, :unknown_outcome}` (a lost response); that is
  never proof of rollback, and callers resolve it by looking up the same
  command ID. A PostgreSQL adapter (milestone 2) implements this same port.
  """

  @type store :: term()
  @type batch :: %{position: pos_integer(), command_id: String.t(), events: [map()]}
  @type receipt :: map()

  @callback head(store) :: non_neg_integer()
  @callback read_from(store, after_position :: non_neg_integer()) :: [batch]
  @callback receipt(store, command_id :: String.t()) :: {:ok, receipt} | :none
  @callback append(store, expected :: non_neg_integer(), command_id :: String.t(), [map()], receipt) ::
              {:ok, store, non_neg_integer()}
              | {:error, :conflict | :unavailable, store}
              | {:error, :unknown_outcome, store}
end
