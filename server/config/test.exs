import Config

config :feud_hall, FeudHall.Infrastructure.Repo,
  database: System.get_env("FEUD_HALL_TEST_DB", "feud_hall_test"),
  pool_size: 6,
  username: System.get_env("PGUSER") || System.get_env("USER"),
  password: System.get_env("PGPASSWORD"),
  hostname: System.get_env("PGHOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  parameters: [lock_timeout: "2000"]

config :logger, level: :warning

# A repo nothing listens for (port 1), started only by the refused-connection test. One
# connection, a short connect timeout, and a slow reconnect backoff keep it quick and quiet.
config :feud_hall, FeudHall.UnreachableRepo,
  database: "feud_hall_unreachable",
  hostname: "localhost",
  port: 1,
  pool_size: 1,
  connect_timeout: 100,
  queue_target: 20,
  queue_interval: 50,
  backoff_min: 5_000,
  backoff_max: 5_000
