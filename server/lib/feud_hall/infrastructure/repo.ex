defmodule FeudHall.Infrastructure.Repo do
  @moduledoc "PostgreSQL connection pool for the durable event store."
  use Ecto.Repo, otp_app: :feud_hall, adapter: Ecto.Adapters.Postgres
end
