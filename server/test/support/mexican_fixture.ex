defmodule FeudHall.MexicanFixture do
  @moduledoc "The original single-cuisine catalog for scenarios with pinned prices, portions, or event bytes."

  alias FeudHall.Infrastructure.EventCodec

  @external_resource Path.expand("../fixtures/events/hall_initialized.json", __DIR__)
  {:ok, %{catalog: catalog}} = @external_resource |> File.read!() |> EventCodec.decode()
  @catalog catalog

  def catalog, do: @catalog

  def catalog(enable: enabled) do
    update_in(@catalog.profiles, fn profiles ->
      Map.new(profiles, fn {id, profile} -> {id, %{profile | enabled: id in enabled}} end)
    end)
  end

  def rules, do: @catalog.rules
end
