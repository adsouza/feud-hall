defmodule FeudHall.App do
  @moduledoc "OTP application: supervises the durable-storage infrastructure and the hall authorities."
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      FeudHall.Infrastructure.Repo,
      {DynamicSupervisor, name: FeudHall.AuthoritySupervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: FeudHall.Supervisor)
  end
end
