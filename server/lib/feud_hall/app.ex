defmodule FeudHall.App do
  @moduledoc "OTP application: supervises the durable-storage infrastructure."
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([FeudHall.Infrastructure.Repo], strategy: :one_for_one, name: FeudHall.Supervisor)
  end
end
