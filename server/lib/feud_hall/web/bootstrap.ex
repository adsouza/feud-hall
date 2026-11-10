defmodule FeudHall.Web.Bootstrap do
  @moduledoc false
  use GenServer
  alias FeudHall.Domain.Content.SliceCatalog
  alias FeudHall.Infrastructure.HallAuthority

  def start_link(scope), do: GenServer.start_link(__MODULE__, scope)

  @impl true
  def init(scope) do
    case HallAuthority.state(FeudHall.LiveAuthority).hall do
      nil ->
        command = %{
          command_id: "web-init",
          actor: {:system, :admin},
          command: {:initialize_hall, %{hall_id: scope, catalog: SliceCatalog.catalog(), managed: true}}
        }

        case HallAuthority.execute(FeudHall.LiveAuthority, command) do
          {status, %{outcome: :accepted}} when status in [:accepted, :replayed] -> {:ok, scope}
          other -> {:stop, {:hall_bootstrap_failed, elem(other, 0)}}
        end

      %{management: _} ->
        {:ok, scope}

      _ ->
        {:stop, :managed_hall_required}
    end
  end
end
