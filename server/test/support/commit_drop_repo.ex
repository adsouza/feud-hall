defmodule FeudHall.CommitDropRepo do
  @moduledoc """
  Test-only repo wrapper that delegates to `FeudHall.Infrastructure.Repo` but
  raises `DBConnection.ConnectionError` after a transaction has committed, as a
  connection dropped while the COMMIT reply was in flight would. Adapters must
  treat that as an unknown outcome, not a rollback.
  """

  alias FeudHall.Infrastructure.Repo

  def query(sql, params \\ [], opts \\ []), do: Repo.query(sql, params, opts)
  def query!(sql, params \\ [], opts \\ []), do: Repo.query!(sql, params, opts)
  def insert_all(source, entries, opts \\ []), do: Repo.insert_all(source, entries, opts)
  def rollback(value), do: Repo.rollback(value)

  def transaction(fun, opts \\ []) do
    case Repo.transaction(fun, opts) do
      {:ok, _} -> raise DBConnection.ConnectionError, "connection lost after commit (injected)"
      other -> other
    end
  end
end
