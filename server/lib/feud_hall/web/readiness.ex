defmodule FeudHall.Web.Readiness do
  @moduledoc "Checks both live clock readiness and durable ownership without advancing gameplay."
  alias FeudHall.Infrastructure.{HallAuthority, Repo}

  def ready?(authority) do
    with {:ready, scope, owner, epoch} <- HallAuthority.readiness(authority),
         {:ok, %{rows: [[^owner, ^epoch]]}} <-
           Repo.query("select owner, epoch from authority where scope = $1", [scope], timeout: 1_000) do
      true
    else
      _ -> false
    end
  catch
    :exit, {:noproc, _} -> false
    :exit, {:timeout, _} -> false
  end
end
