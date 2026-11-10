defmodule FeudHall.Web.Bootstrap do
  @moduledoc false
  use GenServer
  alias FeudHall.Domain.Content.LaunchCatalog
  alias FeudHall.Infrastructure.HallAuthority

  def start_link(scope, catalog \\ LaunchCatalog.catalog()), do: GenServer.start_link(__MODULE__, {scope, catalog})

  @impl true
  def init({scope, catalog}) do
    case HallAuthority.state(FeudHall.LiveAuthority).hall do
      nil ->
        execute(scope, "web-init", {:initialize_hall, %{hall_id: scope, catalog: catalog, managed: true}})

      %{management: _, catalog: %{id: "slice"}} when catalog.id == "launch" ->
        execute(scope, "web-launch-catalog", {:expand_catalog, %{catalog: catalog}})

      %{management: _} ->
        {:ok, scope}

      _ ->
        {:stop, :managed_hall_required}
    end
  end

  defp execute(scope, id, command) do
    envelope = %{command_id: id, actor: {:system, :admin}, command: command}

    case HallAuthority.execute(FeudHall.LiveAuthority, envelope) do
      {status, %{outcome: :accepted}} when status in [:accepted, :replayed] -> {:ok, scope}
      other -> {:stop, {:hall_bootstrap_failed, elem(other, 0)}}
    end
  end
end
