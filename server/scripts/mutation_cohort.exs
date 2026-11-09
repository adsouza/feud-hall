# Curated semantic mutation cohort for the economic core.
#
# Usage (from server/):  elixir scripts/mutation_cohort.exs <empty-work-dir>
#
# Copies this project into the work directory and never edits the original
# checkout. One worker, serial: verifies the unmutated baseline, applies each
# exact patch (which must match exactly once), compiles, runs only the
# selected focused test files with `--max-cases 1`, restores the file, and
# re-verifies the baseline at the end. Outcomes are reported separately:
# killed (a test assertion failed), survived, invalid (patch or compile
# failure), timeout, and harness failure. A timeout or compile failure is
# never counted as a kill.

defmodule MutationCohort do
  @timeout_s "300"

  @tray "test/feud_hall/domain/tray_lifecycle_test.exs"
  @stock "test/feud_hall/domain/cleaning_and_stock_test.exs"
  @diet "test/feud_hall/domain/dietary_and_content_test.exs"
  @flow "test/feud_hall/application/command_workflow_test.exs"
  @prop "test/feud_hall/properties/hall_trace_property_test.exs"
  @clock "test/feud_hall/domain/clock_test.exs"
  @pg_store "test/feud_hall/infrastructure/postgres_event_store_test.exs"
  @pg_atomic "test/feud_hall/infrastructure/postgres_atomicity_test.exs"
  @projector "test/feud_hall/infrastructure/daily_activity_projector_test.exs"
  @recovery "test/feud_hall/application/recovery_test.exs"
  @diag "test/feud_hall/application/diagnostics_test.exs"
  @authority "test/feud_hall/infrastructure/hall_authority_test.exs"
  @memory_store "test/feud_hall/infrastructure/in_memory_event_store_test.exs"
  @store "lib/feud_hall/infrastructure/postgres_event_store.ex"

  def mutants do
    [
      {"ready-food expiry loses its exact tie", "lib/feud_hall/domain/hall/decider.ex",
       "order.status == :ready and state.now < order.ready_expires_at",
       "order.status == :ready and state.now <= order.ready_expires_at", [@tray]},
      {"cleaning gate opens at exactly 03:00", "lib/feud_hall/domain/clock.ex",
       "tod >= @cleaning_start and tod < @cleaning_end", "tod > @cleaning_start and tod < @cleaning_end",
       [@stock, @clock]},
      {"cancellation omits reservation release", "lib/feud_hall/domain/hall/evolver.ex",
       "    |> update_in([:restaurants, rid, :batches], &Inventory.adjust_reserved(&1, order.reservations, -1))\n    |> post(rid, wip:",
       "    |> post(rid, wip:", [@tray]},
      {"dessert accepted before main service", "lib/feud_hall/domain/hall/decider.ex",
       ":ok <- ensure(visit.dessert == :offered, :no_dessert_offer),\n         :ok <- ensure(state.now < visit.dessert_offer_deadline",
       ":ok <- ensure(visit.dessert in [:offered, :none], :no_dessert_offer),\n         :ok <- ensure(state.now < visit.dessert_offer_deadline",
       [@tray]},
      {"dietary origin filter bypassed", "lib/feud_hall/domain/dietary.ex",
       "with :ok <- check_origins(catalog, requirement.excludes, lines) do", "with :ok <- :ok do", [@diet]},
      {"carbohydrate rounded down", "lib/feud_hall/domain/dietary.ex", "{:ok, scaled} -> {:ok, ceil_div(scaled, 1000)}",
       "{:ok, scaled} -> {:ok, div(scaled, 1000)}", [@diet]},
      {"dessert ceiling ignores served courses", "lib/feud_hall/domain/offers.ex",
       "{:ok, dessert_id} <- dessert_recipe(state, restaurant),\n         available = Inventory.availability(restaurant.batches, state.now),\n         committed = visit.carbs_reserved + visit.carbs_served,",
       "{:ok, dessert_id} <- dessert_recipe(state, restaurant),\n         available = Inventory.availability(restaurant.batches, state.now),\n         committed = 0,",
       [@diet]},
      {"confirmed item terms not compared", "lib/feud_hall/domain/offers.ex",
       "Map.get(confirmed, :components) != current.components -> {:error, :stale_terms}",
       "false -> {:error, :stale_terms}", [@tray]},
      {"voluntary cancellation after preparation", "lib/feud_hall/domain/hall/decider.ex",
       ":ok <- ensure(Enum.all?(tray.components, &(state.orders[&1].status == :reserved)), :preparation_started)",
       ":ok <- ensure(true, :preparation_started)", [@tray]},
      {"substitution penalty cap dropped", "lib/feud_hall/domain/substitution.ex",
       "          |> Enum.sum()\n          |> min(catalog.rules.substitution_penalty_cap)", "          |> Enum.sum()",
       [@stock]},
      {"receipt fingerprint not checked", "lib/feud_hall/application/command_workflow.ex",
       "{:ok, %{fingerprint: ^fingerprint} = receipt} -> {:replayed, receipt}",
       "{:ok, receipt} -> {:replayed, receipt}", [@flow]},
      {"expected-version check skipped", "lib/feud_hall/infrastructure/in_memory_event_store.ex",
       "request.expected_position != store.head ->", "false ->", [@flow, @memory_store]},
      {"tray cancellation forgets visit finalization", "lib/feud_hall/domain/hall/settlement.ex",
       "[cancelled, finalize_event(state1, state1.visits[tray.visit], visit_reason(reason))]", "[cancelled]", [@tray]},
      {"deadline tie lost to patience", "lib/feud_hall/domain/hall/advance.ex",
       "{t.deadline + 1, 3, {:tray_deadline, tid}}", "{t.deadline, 3, {:tray_deadline, tid}}", [@tray]},
      {"consumed food not classified as waste", "lib/feud_hall/domain/hall/evolver.ex",
       "|> post(rid, wip: -order.consumed_cost, waste: order.consumed_cost)",
       "|> post(rid, wip: -order.consumed_cost, waste: 0)", [@stock]},
      {"ingredients consumed twice", "lib/feud_hall/domain/hall/evolver.ex",
       "Enum.reduce(e.consumed, batches, &consume_batch(&2, &1))",
       "Enum.reduce(e.consumed ++ e.consumed, batches, &consume_batch(&2, &1))", [@stock]},
      {"simulated budget ignored", "lib/feud_hall/domain/hall/decider.ex", "if quote.total <= budget,", "if true,",
       [@prop]},
      {"postgres append skips the head position check", @store,
       "if position != request.expected_position, do: repo.rollback(:conflict)",
       "if false, do: repo.rollback(:conflict)", [@pg_store, @pg_atomic]},
      {"postgres append skips the authority epoch check", @store,
       "if authority_epoch(repo, store.scope) != store.epoch, do: repo.rollback(:fenced)",
       "if false, do: repo.rollback(:fenced)", [@pg_atomic, @pg_store]},
      {"postgres append writes events without the receipt", @store,
       "    insert_receipt(repo, request, position)\n\n    if hooks.before_commit", "    if hooks.before_commit",
       [@pg_store]},
      {"postgres append accepts half a batch", @store,
       "      advance_stream(repo, @control, versions.control + length(control_events), control_events)\n    end\n",
       "    end\n", [@pg_store, @pg_atomic]},
      {"projector checkpoint guard relaxed", "lib/feud_hall/infrastructure/postgres/daily_activity_projector.ex",
       "update projector_checkpoints set position = $1 where name = $2 and position = $3",
       "update projector_checkpoints set position = $1 where name = $2 and position <> $3", [@projector]},
      {"projector checkpoint advances without deltas",
       "lib/feud_hall/infrastructure/postgres/daily_activity_projector.ex",
       "            add_deltas(repo, DailyActivity.deltas(batch))\n", "", [@projector]},
      {"recovery replay calls side effects", "lib/feud_hall/application/recovery.ex", "restored = restore(base, tail),",
       "restored = (if(fx = opts[:side_effects], do: Enum.each(tail, fx)); restore(base, tail)),", [@recovery]},
      {"candidate state adopted before append succeeds", "lib/feud_hall/application/command_workflow.ex",
       "{:error, reason, %{runtime | store: store}}",
       "{:error, reason, %{runtime | store: store, state: candidate, control: candidate_control}}", [@flow]},
      {"accepted emitted before append", "lib/feud_hall/application/command_workflow.ex",
       "    case runtime.store_mod.append(runtime.store, request) do\n",
       "    Diagnostics.emit(runtime.diagnostics, :command_outcome, %{outcome: :accepted, position: runtime.position})\n\n    case runtime.store_mod.append(runtime.store, request) do\n",
       [@diag]},
      {"authority charges the gap instead of recovering", "lib/feud_hall/infrastructure/hall_authority.ex",
       "if elapsed > s.max_gap_ms do", "if false do", [@authority]}
    ]
  end

  def run([work]) do
    src = File.cwd!()
    unless File.exists?(Path.join(src, "mix.exs")), do: abort("run from server/")
    if File.exists?(work) and File.ls!(work) != [], do: abort("work dir must be empty or absent")

    dir = Path.join(work, "server")
    File.mkdir_p!(dir)

    for entry <- File.ls!(src),
        entry not in ["cover", "scripts"],
        do: File.cp_r!(Path.join(src, entry), Path.join(dir, entry))

    selected = mutants() |> Enum.flat_map(&elem(&1, 4)) |> Enum.uniq()
    IO.puts("baseline (#{length(selected)} focused files)...")
    baseline!(dir, selected)

    results =
      for {name, file, from, to, tests} <- mutants() do
        path = Path.join(dir, file)
        original = File.read!(path)
        started = System.monotonic_time(:millisecond)

        outcome =
          case count(original, from) do
            1 ->
              File.write!(path, String.replace(original, from, to))
              outcome = evaluate(dir, tests)
              File.write!(path, original)
              outcome

            n ->
              {:invalid, "patch matched #{n} times"}
          end

        ms = System.monotonic_time(:millisecond) - started
        IO.puts("#{pad(label(outcome))} #{name} (#{ms} ms)")
        %{name: name, file: file, tests: tests, outcome: outcome, ms: ms}
      end

    IO.puts("re-verifying baseline after restore...")
    baseline!(dir, selected)

    summary = results |> Enum.frequencies_by(&label(&1.outcome))
    IO.puts("\nsummary: #{inspect(summary)} of #{length(results)} curated mutants")
    File.write!(Path.join(work, "mutation_report.txt"), Enum.map_join(results, "\n", &inspect/1))

    if Map.get(summary, "SURVIVED", 0) + Map.get(summary, "INVALID", 0) + Map.get(summary, "TIMEOUT", 0) +
         Map.get(summary, "HARNESS", 0) > 0,
       do: System.halt(1)
  end

  defp evaluate(dir, tests) do
    # Mutants may legitimately leave helpers unused, so warnings are allowed;
    # only a genuine compile error makes a mutant invalid.
    case cmd(dir, ["compile"]) do
      {_, 0} ->
        Enum.reduce_while(tests, :survived, fn test, _ ->
          case cmd(dir, ["test", test, "--max-cases", "1"]) do
            {_, 0} ->
              {:cont, :survived}

            {_, 124} ->
              {:halt, :timeout}

            {out, _} ->
              if out =~ ~r/Failed: \d+|\d+ failures?/, do: {:halt, {:killed, test}}, else: {:halt, {:harness, out}}
          end
        end)

      {out, _} ->
        {:invalid, String.slice(out, 0, 300)}
    end
  end

  defp baseline!(dir, tests) do
    for test <- tests do
      case cmd(dir, ["test", test, "--max-cases", "1"]) do
        {_, 0} -> :ok
        {out, _} -> abort("baseline failed for #{test}:\n#{out}")
      end
    end
  end

  defp cmd(dir, args),
    do:
      System.cmd("timeout", [@timeout_s, "mix" | args],
        cd: dir,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "test"}, {"FEUD_HALL_TEST_DB", "feud_hall_mutation"}]
      )

  defp count(text, pattern), do: length(String.split(text, pattern)) - 1

  defp label({:killed, _}), do: "KILLED"
  defp label(:survived), do: "SURVIVED"
  defp label({:invalid, _}), do: "INVALID"
  defp label(:timeout), do: "TIMEOUT"
  defp label({:harness, _}), do: "HARNESS"

  defp pad(s), do: String.pad_trailing(s, 9)

  defp abort(msg) do
    IO.puts(:stderr, msg)
    System.halt(2)
  end
end

MutationCohort.run(System.argv())
