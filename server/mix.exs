defmodule FeudHall.MixProject do
  use Mix.Project

  def project do
    [
      app: :feud_hall,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [mod: {FeudHall.App, []}, extra_applications: [:logger, :crypto]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]]
  end

  defp deps do
    [
      {:phoenix, "1.8.16"},
      {:bandit, "1.14.1"},
      {:jason, "~> 1.4"},
      {:ecto_sql, "~> 3.14"},
      {:postgrex, "~> 0.22"},
      {:stream_data, "~> 1.4", only: :test}
    ]
  end
end
