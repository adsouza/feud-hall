defmodule FeudHall.App do
  @moduledoc "OTP application: supervises the durable-storage infrastructure and the hall authorities."
  use Application

  @impl true
  def start(_type, _args) do
    preload_modules()

    children = [
      FeudHall.Infrastructure.Repo,
      {Registry, keys: :unique, name: FeudHall.Infrastructure.Diagnostics.Exporter.Registry},
      {DynamicSupervisor, name: FeudHall.AuthoritySupervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: FeudHall.Supervisor)
  end

  @doc """
  Loads every module of the application. Stored terms (snapshots, receipts, outbox payloads, and
  content) are decoded with `binary_to_term(..., [:safe])`, which refuses an atom that does not
  exist yet, and an atom named only in a module that has not been loaded does not exist. In an
  interactive VM modules load lazily, so without this a valid snapshot written by one VM would be
  rejected by a freshly started one. It runs before any child starts.
  """
  @spec preload_modules() :: :ok
  def preload_modules do
    :feud_hall |> Application.spec(:modules) |> Code.ensure_all_loaded!()
    :ok
  end
end
