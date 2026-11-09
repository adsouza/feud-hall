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

  A request is `:invalid_request` (nothing written) when it carries outbox
  intents without events, hall events without a hall stream, or an outbox kind
  outside `outbox_kinds/0`. A `dedupe_key` already used by an earlier batch, or
  repeated within the request, is a `:conflict`.

  An append may report `{:error, :unknown_outcome, store}` (a lost response);
  that is never proof of rollback, and callers resolve it by looking up the
  same command ID. Snapshot callbacks return the store like `append/2`, so
  value-typed adapters keep snapshots with the log they describe. Stream
  versions count events: a stream's version advances
  by the number of events appended to it and is unchanged by a batch that has
  none for it.
  """

  alias FeudHall.Application.Projections.Balances

  # Outbox kinds an adapter accepts. Adapters map stored text back to these atoms
  # (never `String.to_atom/1`), so a new kind is added here with its consumer.
  @outbox_kinds [:test_notice]

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

  @doc "Outbox kinds the port accepts; any other kind is an `:invalid_request`."
  def outbox_kinds, do: @outbox_kinds

  @doc """
  Shape checks every adapter applies before touching storage: intents need a
  batch to belong to (a rejection receipt carries none), hall events need a
  hall stream, and kinds must be allowlisted.
  """
  @spec validate_request(append_request()) :: :ok | :invalid_request
  def validate_request(%{events: events, control_events: control, outbox: outbox, hall_stream: stream}) do
    cond do
      outbox != [] and events == [] and control == [] -> :invalid_request
      events != [] and is_nil(stream) -> :invalid_request
      Enum.any?(outbox, &(&1.kind not in @outbox_kinds)) -> :invalid_request
      true -> :ok
    end
  end

  @callback head(store) :: non_neg_integer()
  @callback stream_versions(store, hall_stream :: String.t() | nil) :: versions()
  @callback read_from(store, after_position :: non_neg_integer()) ::
              {:ok, [batch]} | {:error, {:undecodable, pos_integer(), term()}}
  @callback receipt(store, command_id :: String.t()) :: {:ok, receipt} | :none
  @callback append(store, append_request) ::
              {:ok, store, non_neg_integer()}
              | {:error, :conflict | :fenced | :unavailable | :invalid_request, store}
              | {:error, :unknown_outcome, store}
  @callback acquire_authority(store, scope :: String.t(), owner :: String.t()) ::
              {:ok, store, pos_integer()} | {:error, :unavailable}
  @callback save_snapshot(store, position :: non_neg_integer(), binary()) ::
              {:ok, store, snapshot_id :: term()} | {:error, :unavailable}
  @callback mark_snapshot_verified(store, snapshot_id :: term()) ::
              {:ok, store} | {:error, :unknown_snapshot}
  @doc "Stored snapshots, newest first (by position, then id)."
  @callback snapshots(store) :: [snapshot()] | {:error, :unavailable}
  @callback projection(store, :balances | :stock) :: [map()]
  @doc "Committed outbox intents in insertion order."
  @callback outbox(store) :: [
              %{
                dedupe_key: String.t(),
                command_id: String.t(),
                position: non_neg_integer(),
                kind: atom(),
                payload: map()
              }
            ]
end
