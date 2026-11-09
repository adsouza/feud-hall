import Config

config :feud_hall, FeudHall.Infrastructure.Repo,
  database: "feud_hall_dev",
  pool_size: 6,
  username: System.get_env("PGUSER") || System.get_env("USER"),
  password: System.get_env("PGPASSWORD"),
  hostname: System.get_env("PGHOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  parameters: [lock_timeout: "2000"]
