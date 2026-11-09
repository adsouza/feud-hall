defmodule FeudHall.AppTest do
  # Not async: `preload_modules/0` loads code for the whole VM.
  use ExUnit.Case, async: false

  # Stored terms (snapshots, receipts, outbox payloads, content) are decoded with `[:safe]`, which
  # refuses atoms that do not exist yet; an atom defined only in a module that has not been loaded
  # does not exist. The application therefore loads all of its modules before anything decodes.
  test "the application had loaded every one of its modules before the first test ran" do
    assert :persistent_term.get({__MODULE__, :unloaded_at_start}) == []
  end

  test "preload_modules/0 loads every module the application lists" do
    modules = Application.spec(:feud_hall, :modules)
    assert FeudHall.Infrastructure.Snapshot in modules
    assert :ok = FeudHall.App.preload_modules()
    assert Enum.reject(modules, &:code.is_loaded/1) == []
  end
end
