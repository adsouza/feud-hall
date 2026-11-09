# Property budgets are explicit and bounded; see docs/TESTING.md.
# Database tests are async: false and start from truncated tables (FeudHall.PostgresCase).

# Recorded before any test can load code: FeudHall.App preloads every application module at start.
:persistent_term.put(
  {FeudHall.AppTest, :unloaded_at_start},
  Enum.reject(Application.spec(:feud_hall, :modules), &:code.is_loaded/1)
)

ExUnit.start()
