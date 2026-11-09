defmodule FeudHall.Application.EventStore do
  @moduledoc """
  Application-owned event-store port (version 2).

  An append is one request: the hall stream's events and the control stream's
  events, the immutable receipt, outbox intents, and the synchronous
  projection rows commit atomically or not at all. The adapter checks the
  expected global position, the expected version of each stream, and (for
  durable adapters) the authority epoch, and returns `:conflict` or `:fenced`
  with nothing written. A request with no events records only its receipt
  (a rejection) and appends no batch, so the position is unchanged.

  An append may report `{:error, :unknown_outcome, store}` (a lost response);
  that is never proof of rollback, and callers resolve it by looking up the
  same command ID. Stream versions count events: a stream's version advances
  by the number of events appended to it and is unchanged by a batch that has
  none for it.
  """

  alias FeudHall.Application.Projections.Balances

  @type store :: term()
  @type versions :: %{hall: non_neg_integer(), control: non_neg_integer()}
  @type batch :: %{
          position: pos_integer(),
          command_id: String.t(),
          hall_ms: non_neg_integer() | nil,
          events: [map()],
          control_events: [map()]
        }
  @type receipt :: map()
  @type append_request :: %{
          command_id: String.t(),
          expected_position: non_neg_integer(),
          expected_versions: versions(),
          hall_stream: String.t() | nil,
          events: [map()],
          control_events: [map()],
          receipt: receipt(),
          outbox: [%{dedupe_key: String.t(), kind: atom(), payload: map()}],
          projection_rows: [Balances.row()],
          context: %{
            actor: term(),
            correlation_id: String.t(),
            content_hash: String.t() | nil,
            hall_ms: non_neg_integer() | nil
          }
        }
  @type snapshot :: %{id: term(), position: non_neg_integer(), body: binary(), verified: boolean()}

  @callback head(store) :: non_neg_integer()
  @callback stream_versions(store, hall_stream :: String.t() | nil) :: versions()
  @callback read_from(store, after_position :: non_neg_integer()) ::
              {:ok, [batch]} | {:error, {:undecodable, pos_integer(), term()}}
  @callback receipt(store, command_id :: String.t()) :: {:ok, receipt} | :none
  @callback append(store, append_request) ::
              {:ok, store, non_neg_integer()}
              | {:error, :conflict | :fenced | :unavailable, store}
              | {:error, :unknown_outcome, store}
  @callback acquire_authority(store, scope :: String.t(), owner :: String.t()) ::
              {:ok, store, pos_integer()} | {:error, :unavailable}
  @callback save_snapshot(store, position :: non_neg_integer(), binary()) ::
              {:ok, snapshot_id :: term()} | {:error, :unavailable}
  @callback mark_snapshot_verified(store, snapshot_id :: term()) :: :ok
  @doc "Stored snapshots, newest first."
  @callback snapshots(store) :: [snapshot()]
  @callback projection(store, :balances | :stock) :: [map()]
end
