defmodule FeudHall.App do
  @moduledoc "OTP application: supervises the durable-storage infrastructure and the hall authorities."
  use Application

  @impl true
  def start(_type, _args) do
    preload_modules()

    children = [
      FeudHall.Infrastructure.Repo,
      {Phoenix.PubSub, name: FeudHall.PubSub},
      FeudHall.Web.RateLimit,
      {Registry, keys: :unique, name: FeudHall.Infrastructure.Diagnostics.Exporter.Registry},
      {DynamicSupervisor, name: FeudHall.AuthoritySupervisor, strategy: :one_for_one}
    ]

    children = if Application.get_env(:feud_hall, :serve, false), do: children ++ live_children(), else: children
    Supervisor.start_link(children, strategy: :one_for_one, name: FeudHall.Supervisor)
  end

  defp live_children do
    alias FeudHall.Infrastructure.{HallAuthority, PostgresEventStore, Repo, SystemClock}
    alias FeudHall.Infrastructure.Diagnostics.Exporter
    scope = Application.fetch_env!(:feud_hall, :hall_id)

    [
      {Exporter,
       [
         name: FeudHall.LiveDiagnostics,
         max_queue: 256,
         batch: 16,
         timeout_ms: 2_000,
         export: &FeudHall.Web.Diagnostics.export/1
       ]},
      Supervisor.child_spec(
        {HallAuthority,
         [
           name: FeudHall.LiveAuthority,
           diagnostics: {Exporter, FeudHall.LiveDiagnostics},
           scope: scope,
           store_mod: PostgresEventStore,
           store: PostgresEventStore.new(Repo, scope),
           clock: {SystemClock, nil}
         ]},
        restart: :transient
      ),
      {FeudHall.Web.Bootstrap, scope},
      FeudHall.Web.Endpoint
    ]
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
