defmodule FeudHall.PostgresCase do
  @moduledoc """
  Case template for tests that use the PostgreSQL event store. Modules are `async: false` and
  start from truncated tables with `append_head` re-seeded at position 0.
  """
  use ExUnit.CaseTemplate

  alias FeudHall.Infrastructure.{PostgresEventStore, Repo}

  @tables ~w(append_head stream_heads authority batches events receipts outbox content snapshots
             restaurant_balances restaurant_stock daily_activity projector_checkpoints)

  using do
    quote do
      use ExUnit.Case, async: false
      alias FeudHall.Infrastructure.Repo
    end
  end

  setup do
    reset!()
    :ok
  end

  @doc "Truncates every event-store table and re-seeds the append head at position 0."
  def reset! do
    Repo.query!("truncate #{Enum.join(@tables, ", ")} restart identity")
    Repo.query!("insert into append_head (id, position) values (1, 0)")
    :ok
  end

  @doc "A PostgreSQL store for scope `hall:test` that already holds the scope's authority."
  def fresh_store do
    {:ok, store, _epoch} =
      Repo
      |> PostgresEventStore.new("hall:test")
      |> PostgresEventStore.acquire_authority("hall:test", "test-node")

    store
  end
end
