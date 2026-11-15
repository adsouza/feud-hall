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

  # The two-VM probe: what one VM writes, a freshly started VM must decode with `[:safe]`. A mid-day
  # hall (kitchen, counter, market requests, NPCs, demand) and receipts of an accepted and a rejected
  # command carry atoms from every domain module, so decoding depends on those modules being loaded
  # first. The child VM never starts the application; it only runs the preload. The hall's catalog
  # is retuned and one receipt is a refused retune, so `Tuning` and `Retune` atoms are covered too.
  describe "a freshly started VM" do
    alias FeudHall.Application.CommandWorkflow
    alias FeudHall.Domain.Control
    alias FeudHall.Domain.Content.{SliceCatalog, Tuning}
    alias FeudHall.Infrastructure.{InMemoryEventStore, Snapshot}

    defp receipts do
      {:ok, rt} = CommandWorkflow.open(InMemoryEventStore, InMemoryEventStore.new())
      env = fn id, actor, command -> %{command_id: id, actor: actor, command: command} end
      init = env.("init", {:system, :admin}, {:initialize_hall, %{hall_id: "h", catalog: SliceCatalog.catalog()}})
      {:accepted, accepted, rt} = CommandWorkflow.execute(rt, init)
      bad = env.("bad", {:principal, "alice"}, {:open_stall, %{stall_id: "nope"}})
      {:rejected, rejected, _rt} = CommandWorkflow.execute(rt, bad)
      retune = env.("retune", {:system, :admin}, {:retune_rules, %{tuning: %{}}})

      {:rejected, %{outcome: {:rejected, :retune_unavailable}} = retune_refused, _rt} =
        CommandWorkflow.execute(rt, retune)

      [accepted, rejected, retune_refused]
    end

    defp child(path, preload?) do
      ebin = :feud_hall |> :code.lib_dir() |> Path.join("ebin")

      script = """
      if #{preload?} do
        :ok = Application.load(:feud_hall)
        :ok = FeudHall.App.preload_modules()
      end

      {snapshot, receipts} = :erlang.binary_to_term(File.read!(#{inspect(path)}))
      loaded = FeudHall.Infrastructure.Snapshot.load(snapshot)

      receipts =
        try do
          {:ok, :erlang.binary_to_term(receipts, [:safe])}
        rescue
          ArgumentError -> {:error, :unknown_atom}
        end

      IO.write(:erlang.term_to_binary({loaded, receipts}) |> Base.encode64())
      """

      {out, 0} = System.cmd(System.find_executable("elixir"), ["-pa", ebin, "-e", script], stderr_to_stdout: true)
      out |> String.trim() |> Base.decode64!() |> :erlang.binary_to_term()
    end

    setup do
      {hall, _log} = FeudHall.EventFixtureScenarios.world()
      # Every leave reason, as the day's counters would hold them: atoms only `Choice` defines.
      left = Map.new(FeudHall.Domain.Choice.leave_reasons(), &{&1, 1})
      hall = update_in(hall, [:demand, :today, :left], &Map.merge(&1, left))
      # A retuned catalog: keys only `Tuning` defines.
      hall = update_in(hall.catalog, &Tuning.put(&1, %{Tuning.of(&1) | version: 2}))
      assert hall.catalog.rules.tuning == %{version: 2}
      control = Control.replay([%{type: :availability_started, epoch_id: "e1"}], nil)
      snapshot = Snapshot.take(%{hall: hall, control: control}, 7)
      receipts = receipts()
      dir = Path.join(System.tmp_dir!(), "feud_hall_two_vm_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      path = Path.join(dir, "terms.bin")
      File.write!(path, :erlang.term_to_binary({snapshot, :erlang.term_to_binary(receipts)}))
      on_exit(fn -> File.rm_rf!(dir) end)
      %{path: path, hall: hall, control: control, receipts: receipts}
    end

    test "decodes a mid-day snapshot and receipts once the application's modules are preloaded", ctx do
      assert {{:ok, %{position: 7, state: %{hall: hall, control: control}}}, {:ok, receipts}} = child(ctx.path, true)
      assert hall == ctx.hall
      assert control == ctx.control
      assert receipts == ctx.receipts
    end

    test "without the preload the same bytes are refused, which is what the preload prevents", ctx do
      assert {{:error, :incompatible_snapshot}, {:error, :unknown_atom}} = child(ctx.path, false)
    end

    # `Snapshot.load/1` itself loads the modules whose atoms a cold recovery may meet first: a
    # retuned catalog's keys are defined only in `Tuning`.
    test "without the preload, a snapshot still decodes a retuned catalog's keys", ctx do
      npc = %{fallback_trays_per_day: 10, expected_use: "even_share", starter_shifts: %{"budget" => [5, 17]}}
      hall = %{catalog: %{rules: %{tuning: %{version: 2}, npc: npc}}}
      snapshot = Snapshot.take(%{hall: hall, control: %{}}, 3)
      path = Path.join(Path.dirname(ctx.path), "retuned.bin")
      File.write!(path, :erlang.term_to_binary({snapshot, :erlang.term_to_binary([])}))

      assert {{:ok, %{position: 3, state: %{hall: ^hall}}}, {:ok, []}} = child(path, false)
    end
  end
end
