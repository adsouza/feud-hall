defmodule FeudHall.Infrastructure.Postgres.DailyActivityProjector do
  @moduledoc """
  Asynchronous, checkpointed daily-activity projection.

  Runs on its own connection after the appends have committed; it never takes the append-head lock,
  so it cannot block writers. Each batch is applied in its own transaction: the checkpoint row
  `"daily_activity"` advances only if it is exactly one below the batch's position, which relies on
  batch positions being contiguous (the append head moves by one per stored batch). Zero rows means
  the batch was already applied or arrived out of order, so nothing is added, then the batch's deltas are added to
  `daily_activity`. Both writes commit together or not at all, so a crash leaves the rows and the
  checkpoint unapplied and a redelivered batch adds once. Batches are applied in position order.

  `opts[:before_checkpoint]` is a test hook: a zero-arity function called inside the transaction
  after the deltas are written and before it commits. `opts[:batch_size]` bounds each read.
  """

  alias FeudHall.Application.Projections.DailyActivity
  alias FeudHall.Infrastructure.PostgresEventStore

  @name "daily_activity"
  @batch_size 200

  @spec catch_up(module(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def catch_up(repo, opts \\ []) do
    repo.query!("insert into projector_checkpoints (name, position) values ($1, 0) on conflict do nothing", [@name])
    advance(repo, checkpoint(repo), opts)
  rescue
    DBConnection.ConnectionError -> {:error, :unavailable}
  end

  defp advance(repo, position, opts) do
    case PostgresEventStore.read_after(repo, position, Keyword.get(opts, :batch_size, @batch_size)) do
      {:ok, []} ->
        {:ok, position}

      {:ok, batches} ->
        Enum.each(batches, &apply_batch(repo, &1, opts))
        advance(repo, List.last(batches).position, opts)

      {:error, _} = error ->
        error
    end
  end

  @doc "Applies one batch atomically with its checkpoint advance; a batch already applied or ahead of the next one is skipped."
  @spec apply_batch(module(), map(), keyword()) :: :applied | :skipped
  def apply_batch(repo, %{position: position} = batch, opts \\ []) do
    {:ok, result} =
      repo.transaction(fn ->
        case repo.query!("update projector_checkpoints set position = $1 where name = $2 and position = $3", [
               position,
               @name,
               position - 1
             ]) do
          %{num_rows: 0} ->
            :skipped

          _ ->
            add_deltas(repo, DailyActivity.deltas(batch))
            if hook = opts[:before_checkpoint], do: hook.()
            :applied
        end
      end)

    result
  end

  @doc "Discards the projection, resets the checkpoint to 0, and replays the whole log."
  @spec rebuild(module()) :: {:ok, non_neg_integer()} | {:error, term()}
  def rebuild(repo) do
    {:ok, :ok} =
      repo.transaction(fn ->
        repo.query!("truncate daily_activity")

        repo.query!(
          "insert into projector_checkpoints (name, position) values ($1, 0) " <>
            "on conflict (name) do update set position = 0",
          [@name]
        )

        :ok
      end)

    catch_up(repo)
  end

  @doc "The last position applied to the projection (0 before its first catch-up)."
  @spec checkpoint(module()) :: non_neg_integer()
  def checkpoint(repo) do
    case repo.query!("select position from projector_checkpoints where name = $1", [@name]) do
      %{rows: [[position]]} -> position
      %{rows: []} -> 0
    end
  end

  defp add_deltas(_repo, []), do: :ok

  defp add_deltas(repo, deltas) do
    repo.query!(
      """
      insert into daily_activity (day, restaurant_id, visits_admitted, trays_accepted)
      select * from unnest($1::int[], $2::text[], $3::int[], $4::int[])
      on conflict (day, restaurant_id) do update set
        visits_admitted = daily_activity.visits_admitted + excluded.visits_admitted,
        trays_accepted = daily_activity.trays_accepted + excluded.trays_accepted
      """,
      [
        Enum.map(deltas, & &1.day),
        Enum.map(deltas, & &1.restaurant_id),
        Enum.map(deltas, & &1.visits_admitted),
        Enum.map(deltas, & &1.trays_accepted)
      ]
    )

    :ok
  end
end
