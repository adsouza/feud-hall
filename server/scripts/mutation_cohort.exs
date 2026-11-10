# Curated semantic mutation cohort for the economic core.
#
# Usage (from server/):  elixir scripts/mutation_cohort.exs <empty-work-dir>
#                        elixir scripts/mutation_cohort.exs --check
#                        elixir scripts/mutation_cohort.exs <empty-work-dir> --match <name-fragment>
#
# `--check` only counts how often each patch's source string occurs in the
# checkout (it must be exactly once) and runs nothing else.
#
# Copies this project into the work directory and never edits the original
# checkout (inside the copy, each patched file is restored even if the run is
# interrupted by an exception). One worker, serial: verifies the unmutated baseline, applies each
# exact patch (which must match exactly once), compiles, runs only the
# selected focused test files with `--max-cases 1`, restores the file, and
# re-verifies the baseline at the end. Outcomes are reported separately:
# killed (a test assertion failed), survived, invalid (patch or compile
# failure), timeout, and harness failure. A timeout or compile failure is
# never counted as a kill.

defmodule MutationCohort do
  @timeout_s "300"
  @seed "1702"
  @formatter ["--formatter", "FeudHall.MutationFormatter"]

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
  @market "test/feud_hall/domain/market_test.exs"
  @market_flow "test/feud_hall/domain/market_flow_test.exs"
  @arrivals "test/feud_hall/domain/arrivals_test.exs"
  @choice "test/feud_hall/domain/choice_test.exs"
  @kitchen "test/feud_hall/domain/automatic_kitchen_test.exs"
  @planner "test/feud_hall/domain/npc_planner_test.exs"
  @npc_plan "test/feud_hall/domain/npc_plan_test.exs"
  @forecast "test/feud_hall/domain/demand_forecast_test.exs"
  @management "test/feud_hall/application/management_test.exs"
  @retention "test/feud_hall/domain/retention_test.exs"

  def mutants do
    [
      {"M3 standby erroneously grants licensing eligibility", "lib/feud_hall/domain/hall/management.ex",
       "and work.tasks > 0", "and work.tasks >= 0", [@management]},
      {"M3 a revoked device remains authenticated", "lib/feud_hall/domain/identity.ex",
       "do: put_in(state.devices[device], nil)", "do: state", [@management]},
      {"M3 allowance can be claimed again from a second device", "lib/feud_hall/domain/hall/management.ex",
       "state.management.allowance_days[id] == day ->", "state.management.allowance_days[id] == day + 1 ->",
       [@management]},
      {"M3 allowance fund is not renewed at midnight", "lib/feud_hall/domain/hall/management.ex",
       "      state = %{state | visitor_fund: state.catalog.rules.visitor_fund}\n", "", [@management]},
      {"M3 a held stall is offered to another owner", "lib/feud_hall/domain/hall/management.ex",
       "and not Map.has_key?(state.stalls, sid) and not reserved?(state, sid) do",
       "and not Map.has_key?(state.stalls, sid) do", [@management]},
      {"M3 off-duty NPC refusal is missing from the event codec", "lib/feud_hall/infrastructure/event_codec.ex",
       "    staff_off_duty unpaid_rent owner_absent\n", "    unpaid_rent owner_absent\n", [@npc_plan]},
      {"M3 selecting a tray prematurely credits a completed handover", "lib/feud_hall/domain/hall/management.ex",
       "  def evolve(state, %{type: :helper_choice_selected} = e),\n    do: put_in(state.management.selections[e.stall_id].choice, {e.item.kind, e.item.id})",
       "  def evolve(state, %{type: :helper_choice_selected} = e) do\n    state\n    |> put_in([:management, :selections, e.stall_id, :choice], {e.item.kind, e.item.id})\n    |> update_in([:management, :shifts, state.management.shift_by_stall[e.stall_id], :tasks], &(&1 + 1))\n  end",
       [@management]},
      {"expiry loses its exact tie to same-instant service (class 1 sorted after class 3)",
       "lib/feud_hall/domain/hall/advance.ex", "      {1, &expiries/1},\n", "      {3.5, &expiries/1},\n", [@tray]},
      {"cleaning gate opens at exactly 03:00", "lib/feud_hall/domain/clock.ex",
       "tod >= @cleaning_start and tod < @cleaning_end", "tod > @cleaning_start and tod < @cleaning_end",
       [@stock, @clock]},
      {"cancellation omits reservation release", "lib/feud_hall/domain/hall/evolver.ex",
       "    |> update_in([:restaurants, rid, :batches], &Inventory.adjust_reserved(&1, order.reservations, -1))\n    |> post(rid, wip:",
       "    |> post(rid, wip:", [@tray]},
      {"dessert accepted before main service", "lib/feud_hall/domain/hall/admission.ex",
       "  defp dessert_open?(_state, visit), do: visit.dessert == :offered",
       "  defp dessert_open?(_state, visit), do: visit.dessert in [:offered, :none]", [@tray]},
      {"dietary origin filter bypassed", "lib/feud_hall/domain/dietary.ex",
       "with :ok <- check_origins(catalog, requirement.excludes, lines) do", "with :ok <- :ok do", [@diet]},
      {"carbohydrate rounded down", "lib/feud_hall/domain/dietary.ex", "{:ok, scaled} -> {:ok, ceil_div(scaled, 1000)}",
       "{:ok, scaled} -> {:ok, div(scaled, 1000)}", [@diet]},
      {"dessert ceiling ignores served courses", "lib/feud_hall/domain/offers.ex",
       "{:ok, dessert_id} <- dessert_recipe(state, restaurant),\n         available = Inventory.availability(restaurant.batches, state.now),\n         committed = visit.carbs_reserved + visit.carbs_served,",
       "{:ok, dessert_id} <- dessert_recipe(state, restaurant),\n         available = Inventory.availability(restaurant.batches, state.now),\n         committed = 0,",
       [@diet]},
      {"confirmed item terms not compared", "lib/feud_hall/domain/offers.ex",
       "Map.delete(confirmed, :deadline) != Map.delete(current, :deadline) -> {:error, :stale_terms}",
       "false -> {:error, :stale_terms}", [@tray]},
      {"voluntary cancellation after preparation", "lib/feud_hall/domain/hall/decider.ex",
       ":ok <- ensure(Enum.all?(tray.components, &(state.orders[&1].status == :queued_prep)), :preparation_started)",
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
      {"deadline tie lost to service (classes 3 and 4 swapped)", "lib/feud_hall/domain/hall/advance.ex",
       "      {3, &kitchen_completions/1},\n      {4, &deadlines/1},",
       "      {4, &kitchen_completions/1},\n      {3, &deadlines/1},", [@tray]},
      {"consumed food not classified as waste", "lib/feud_hall/domain/hall/evolver.ex",
       "|> post(rid, wip: -order.consumed_cost, waste: order.consumed_cost)",
       "|> post(rid, wip: -order.consumed_cost, waste: 0)", [@stock]},
      {"ingredients consumed twice", "lib/feud_hall/domain/hall/evolver.ex",
       "Enum.reduce(consumed, batches, &consume_batch(&2, &1))",
       "Enum.reduce(consumed ++ consumed, batches, &consume_batch(&2, &1))", [@stock]},
      {"simulated budget ignored", "lib/feud_hall/domain/hall/admission.ex", "if quote.total <= budget,", "if true,",
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
      {"recovery replay calls side effects", "lib/feud_hall/application/recovery.ex",
       "{:ok, restored} <- Replay.load(store_mod, store, base: base, head: head),",
       "{:ok, restored} <- Replay.load(store_mod, store, base: base, head: head),\n         _ = if(fx = opts[:side_effects], do: fx.(restored)),",
       [@recovery]},
      {"candidate state adopted before append succeeds", "lib/feud_hall/application/command_workflow.ex",
       "{:error, reason, %{runtime | store: store}}",
       "{:error, reason, %{runtime | store: store, state: candidate, control: candidate_control}}", [@flow]},
      {"accepted emitted before append", "lib/feud_hall/application/command_workflow.ex",
       "    case runtime.store_mod.append(runtime.store, request) do\n",
       "    Diagnostics.emit(runtime.diagnostics, :command_outcome, %{outcome: :accepted, position: runtime.position})\n\n    case runtime.store_mod.append(runtime.store, request) do\n",
       [@diag]},
      # -- Project B: the shared simulation ------------------------------------------
      {"B1 market rotation tie-break fixed at 0", "lib/feud_hall/domain/market.ex", "      start = rem(batch, n)\n",
       "      start = 0\n", [@market]},
      {"B2 market price clamp removed", "lib/feud_hall/domain/market.ex", "    |> max(floor)\n    |> min(ceiling)\n",
       "", [@market]},
      {"B3 market stock not decremented by fills", "lib/feud_hall/domain/market.ex",
       "Map.update!(stock, f.product, &(&1 - f.qty))", "Map.update!(stock, f.product, & &1)", [@market_flow]},
      {"B4 arrivals during cleaning (hourly weights floored at 1, so no hour has quota 0)",
       "lib/feud_hall/domain/demand.ex", "    weights = rules.hourly_weights\n",
       "    weights = Enum.map(rules.hourly_weights, &max(&1, 1))\n", [@arrivals]},
      {"B5 exposure applied twice", "lib/feud_hall/domain/choice.ex", "div((best_score + variety) * exposure, 1000)}",
       "div(div((best_score + variety) * exposure, 1000) * exposure, 1000)}", [@choice]},
      {"B6 incompatible food allowed in choice (diner's requirement not applied)", "lib/feud_hall/domain/choice.ex",
       "visit = %{requirement: diner.requirement, carbs_reserved: 0, carbs_served: 0}",
       "visit = %{requirement: %{profile_id: nil, excludes: [], carb_ceiling_mg: nil}, carbs_reserved: 0, carbs_served: 0}",
       [@choice]},
      {"B7 handover completes at the 03:00 cutoff (classes 2 and 3 swapped)", "lib/feud_hall/domain/hall/advance.ex",
       "      {2, &cleaning_start/1},\n      {3, &kitchen_completions/1},",
       "      {3, &cleaning_start/1},\n      {2, &kitchen_completions/1},", [@kitchen]},
      {"B7b dispatch (including handover starts) not gated on open access", "lib/feud_hall/domain/hall/advance.ex",
       "defp dispatch(%{access: :open} = state) do", "defp dispatch(state) do", [@kitchen]},
      {"B8 accepted trays kept queued across cleaning", "lib/feud_hall/domain/hall/advance.ex",
       "Enum.reduce(trays ++ desserts ++ offers, {state, []}", "Enum.reduce(desserts ++ offers, {state, []}",
       [@kitchen]},
      {"B9 stage capacity bypassed (prep stations unlimited)", "lib/feud_hall/domain/kitchen.ex",
       "count.(:prep) < prep_n and count.(:queued_prep) > 0", "count.(:queued_prep) > 0", [@kitchen]},
      {"B10 consumed ingredients posted twice", "lib/feud_hall/domain/hall/evolver.ex",
       "    |> post(rid, raw: -consumed_cost, wip: consumed_cost)\n",
       "    |> post(rid, raw: -consumed_cost, wip: consumed_cost)\n    |> post(rid, raw: -consumed_cost, wip: consumed_cost)\n",
       [@kitchen]},
      {"B11 public view leaks a rival's cash to the planner", "lib/feud_hall/domain/public_view.ex",
       "        open?: stall.mode == :open,\n",
       "        open?: stall.mode == :open,\n        cash: state.restaurants[stall.restaurant].ledger.cash,\n",
       [@planner]},
      {"B11b authority hands the planner the full hall state", "lib/feud_hall/infrastructure/hall_authority.ex",
       "Planner.plan(view, Map.put(own, :lease, lease), profile, hall.catalog, rng)",
       "Planner.plan(hall, Map.put(own, :lease, lease), profile, hall.catalog, rng)", [@authority]},
      {"B12 NPC slot not advanced by a plan", "lib/feud_hall/domain/hall/decider.ex",
       "      next_slot_at: slot + Clock.hour(),\n", "      next_slot_at: slot,\n", [@npc_plan]},
      {"B13 a product dropped from day_closed replenishment", "lib/feud_hall/domain/market.ex",
       "    Map.new(Map.keys(catalog.products), fn product ->\n      target =",
       "    Map.new(Enum.drop(Map.keys(catalog.products), 1), fn product ->\n      target =", [@forecast]},
      {"B13b day_closed replenishment not applied to market stock", "lib/feud_hall/domain/hall/evolver.ex",
       "update_in([:market, :stock], &add_stock(&1, e.replenishment))",
       "update_in([:market, :stock], &add_stock(&1, %{}))", [@forecast]},
      {"B14 an accepted dessert may reuse an existing order ID (domain guard removed)",
       "lib/feud_hall/domain/hall/admission.ex",
       "with :ok <- ensure(not Map.has_key?(state.orders, order_id), :order_id_taken),", "with :ok <- :ok,", [@tray]},
      {"authority charges the gap instead of recovering", "lib/feud_hall/infrastructure/hall_authority.ex",
       "if elapsed > s.max_gap_ms do", "if false do", [@authority]},
      # -- Task 20: finished work leaves live state ------------------------------------
      {"R1 finished visits kept in live state (retirement skipped)", "lib/feud_hall/domain/hall/evolver.ex",
       "    |> retire_visit(visit)\n", "", [@retention]}
    ]
  end

  def run(["--check"]) do
    bad =
      for {name, file, from, _to, _tests} <- mutants(),
          n = count(File.read!(file), from),
          n != 1,
          do: IO.puts("#{n} matches: #{name} (#{file})")

    IO.puts("checked #{length(mutants())} patches, #{length(bad)} not matching exactly once")
    if bad != [], do: System.halt(1)
  end

  def run([work]), do: run_cohort(work, mutants())

  def run([work, "--match", fragment]) when byte_size(fragment) > 0 do
    selected = Enum.filter(mutants(), fn {name, _, _, _, _} -> String.contains?(name, fragment) end)
    if selected == [], do: abort("no mutants match #{inspect(fragment)}")
    run_cohort(work, selected)
  end

  defp run_cohort(work, cohort) do
    src = File.cwd!()
    unless File.exists?(Path.join(src, "mix.exs")), do: abort("run from server/")
    if File.exists?(work) and File.ls!(work) != [], do: abort("work dir must be empty or absent")

    dir = Path.join(work, "server")
    File.mkdir_p!(dir)

    for entry <- File.ls!(src),
        entry not in ["cover", "scripts"],
        not String.starts_with?(entry, ".env"),
        do: File.cp_r!(Path.join(src, entry), Path.join(dir, entry))

    selected = cohort |> Enum.flat_map(&elem(&1, 4)) |> Enum.uniq()
    IO.puts("baseline (#{length(selected)} focused files)...")
    baseline!(dir, selected)

    results =
      for {name, file, from, to, tests} <- cohort do
        path = Path.join(dir, file)
        original = File.read!(path)
        started = System.monotonic_time(:millisecond)

        outcome =
          case count(original, from) do
            1 ->
              try do
                File.write!(path, String.replace(original, from, to))
                evaluate(dir, tests)
              after
                File.write!(path, original)
              end

            n ->
              {:invalid, "patch matched #{n} times"}
          end

        ms = System.monotonic_time(:millisecond) - started
        IO.puts("#{pad(label(outcome))} #{name} (#{ms} ms)#{detail(outcome)}")
        %{name: name, file: file, tests: tests, outcome: outcome, ms: ms, seed: @seed}
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
          case cmd(dir, ["test", test, "--max-cases", "1", "--seed", @seed] ++ @formatter) do
            {_, 0} ->
              {:cont, :survived}

            {_, 124} ->
              {:halt, :timeout}

            {out, _} ->
              {:halt, classify_failure(test, out)}
          end
        end)

      {out, _} ->
        {:invalid, String.slice(out, 0, 300)}
    end
  end

  defp classify_failure(test, output) do
    finished? = Regex.match?(~r/^FEUD_HALL_MUTATION_FINISHED$/m, output)
    harness? = Regex.match?(~r/^FEUD_HALL_MUTATION_HARNESS /m, output)

    case Regex.run(~r/^FEUD_HALL_MUTATION_ASSERTION (.+)$/m, output) do
      [_, failing] when finished? and not harness? -> {:killed, test, failing}
      _ -> {:harness, String.slice(output, -1000, 1000)}
    end
  end

  defp baseline!(dir, tests) do
    for test <- tests do
      case cmd(dir, ["test", test, "--max-cases", "1", "--seed", @seed]) do
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

  defp label({:killed, _, _}), do: "KILLED"
  defp label(:survived), do: "SURVIVED"
  defp label({:invalid, _}), do: "INVALID"
  defp label(:timeout), do: "TIMEOUT"
  defp label({:harness, _}), do: "HARNESS"

  defp detail({:killed, test, failing}), do: "\n          by #{test}: #{failing}"
  defp detail({:invalid, why}), do: "\n          #{why}"
  defp detail({:harness, out}), do: "\n          #{out}"
  defp detail(_), do: ""

  defp pad(s), do: String.pad_trailing(s, 9)

  defp abort(msg) do
    IO.puts(:stderr, msg)
    System.halt(2)
  end
end

MutationCohort.run(System.argv())
