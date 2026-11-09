defmodule FeudHall.UnreachableRepo do
  @moduledoc """
  A repo configured (in `config/test.exs`) against a port nothing listens on, so a test can
  observe how adapters report a refused connection. It is not part of the application tree:
  tests start it with `start_supervised/1`.
  """
  use Ecto.Repo, otp_app: :feud_hall, adapter: Ecto.Adapters.Postgres
end
