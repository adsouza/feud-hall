defmodule FeudHall.Infrastructure.Repo.Migrations.IndexDiningHistory do
  use Ecto.Migration

  def change do
    execute(
      """
      create index events_guest_visits on events
        (stream, (payload::json #>> '{e,principal}'), stream_version desc)
        where type = 'visit_admitted' and payload::json #>> '{e,source,$a}' = 'guest'
      """,
      "drop index events_guest_visits"
    )

    execute(
      """
      create index events_visit_history on events
        (stream, (payload::json #>> '{e,visit_id}'), type, stream_version)
        where type in ('tray_accepted', 'dessert_accepted', 'visit_finalized')
      """,
      "drop index events_visit_history"
    )
  end
end
