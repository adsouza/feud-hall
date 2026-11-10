defmodule FeudHall.Infrastructure.Repo.Migrations.IndexServedTrays do
  use Ecto.Migration

  def change do
    execute(
      """
      create index events_served_trays on events
        (stream, (payload::json #>> '{e,tray_id}'), stream_version)
        where type = 'tray_served'
      """,
      "drop index events_served_trays"
    )
  end
end
