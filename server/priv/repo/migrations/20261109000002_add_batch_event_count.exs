defmodule FeudHall.Infrastructure.Repo.Migrations.AddBatchEventCount do
  use Ecto.Migration

  # Each batch records how many event rows it committed, so a read can tell a batch that
  # lost event rows from one that never had them. Existing rows are backfilled from their
  # current events; every stored batch has at least one event.
  def change do
    execute(
      """
      alter table batches add column event_count integer
      """,
      "alter table batches drop column event_count"
    )

    execute(
      """
      update batches set event_count = (select count(*) from events where events.position = batches.position)
      """,
      ""
    )

    execute(
      """
      alter table batches alter column event_count set not null,
        add constraint batches_event_count_positive check (event_count > 0)
      """,
      ""
    )
  end
end
