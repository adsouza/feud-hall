defmodule FeudHall.PostgresCase do
  @moduledoc """
  Case template for tests that use the PostgreSQL event store. Modules are `async: false` and
  start from truncated tables with `append_head` re-seeded at position 0.
  """
  use ExUnit.CaseTemplate

  @tables ~w(append_head stream_heads authority batches events receipts outbox content snapshots
             restaurant_balances restaurant_stock daily_activity projector_checkpoints)

  using do
    quote do
      use ExUnit.Case, async: false
      alias FeudHall.Infrastructure.Repo
    end
  end

  setup do
    FeudHall.Infrastructure.Repo.query!("truncate #{Enum.join(@tables, ", ")} restart identity")
    FeudHall.Infrastructure.Repo.query!("insert into append_head (id, position) values (1, 0)")
    :ok
  end
end
