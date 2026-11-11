defmodule FeudHall.Release do
  @moduledoc "Operations for an assembled Feud Hall release."
  alias FeudHall.Infrastructure.Repo

  def migrate do
    {:ok, versions, _started} = Ecto.Migrator.with_repo(Repo, &Ecto.Migrator.run(&1, :up, all: true))
    IO.puts("Feud Hall migrations applied: #{inspect(versions)}")
  end
end
