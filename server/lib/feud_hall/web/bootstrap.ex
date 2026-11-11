defmodule FeudHall.Web.Bootstrap do
  @moduledoc false
  use GenServer
  alias FeudHall.Domain.Content.LaunchCatalog
  alias FeudHall.Infrastructure.HallAuthority

  def start_link(scope, catalog \\ LaunchCatalog.catalog()), do: GenServer.start_link(__MODULE__, {scope, catalog})

  @impl true
  def init({scope, catalog}) do
    with {:ok, ^scope} <- initialize(scope, catalog),
         do: enable_visitor_play(scope, catalog)
  end

  defp initialize(scope, catalog) do
    case HallAuthority.state(FeudHall.LiveAuthority).hall do
      nil ->
        execute(scope, "web-init", {:initialize_hall, %{hall_id: scope, catalog: catalog, managed: true}})

      %{management: _, catalog: %{id: "slice"}} when catalog.id == "launch" ->
        expand(scope, catalog)

      %{management: _, catalog: %{id: "launch", version: version}}
      when catalog.id == "launch" and catalog.version > version ->
        expand(scope, catalog)

      %{management: _} ->
        {:ok, scope}

      _ ->
        {:stop, :managed_hall_required}
    end
  end

  defp expand(scope, catalog),
    do: execute(scope, "web-launch-catalog:#{catalog.version}", {:expand_catalog, %{catalog: catalog}})

  defp enable_visitor_play(scope, %{id: "launch"}) do
    if Map.has_key?(HallAuthority.state(FeudHall.LiveAuthority).hall, :counter_play),
      do: {:ok, scope},
      else: execute(scope, "web-visitor-play", {:enable_visitor_play, %{}})
  end

  defp enable_visitor_play(scope, _catalog), do: {:ok, scope}

  defp execute(scope, id, command) do
    envelope = %{command_id: id, actor: {:system, :admin}, command: command}

    case HallAuthority.execute(FeudHall.LiveAuthority, envelope) do
      {status, %{outcome: :accepted}} when status in [:accepted, :replayed] -> {:ok, scope}
      other -> {:stop, {:hall_bootstrap_failed, elem(other, 0)}}
    end
  end
end
