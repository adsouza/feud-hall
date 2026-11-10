defmodule FeudHall.Infrastructure.Repo.Migrations.ResetDailyActivityForEventTime do
  use Ecto.Migration

  # Derived rows are rebuilt by the projector from the unchanged event log.
  def up do
    execute("update projector_checkpoints set position = 0 where name = 'daily_activity'")
    execute("truncate daily_activity")
  end

  def down, do: up()
end
