defmodule FeudHall.Infrastructure.PostgresAtomicityTest do
  # Concurrent, crashing, and superseded writers against the real database. Every writer runs in
  # its own process on its own pooled connection; the steps are ordered by messages and by
  # bounded polls of PostgreSQL's own lock and backend views, never by sleeping.
  use FeudHall.PostgresCase

  alias FeudHall.Application.CommandWorkflow, as: Workflow
  alias FeudHall.MexicanFixture
  alias FeudHall.Infrastructure.PostgresEventStore

  import FeudHall.PostgresCase, only: [fresh_store: 0]

  # The connection drop in the kill test is logged by DBConnection; keep it out of passing runs.
  @moduletag :capture_log

  @poll_attempts 20_000
  @guard_ms 15_000

  defp request(id \\ "a") do
    %{
      command_id: id,
      expected_position: 0,
      expected_versions: %{hall: 0, control: 0},
      hall_stream: "hall:h1",
      events: [%{type: :clock_advanced, to: 24}],
      control_events: [%{type: :availability_started, epoch_id: "e-" <> id}],
      receipt: %{command_id: id, fingerprint: "fp-" <> id, kind: :advance_clock, outcome: :accepted},
      outbox: [%{dedupe_key: "mail:" <> id, kind: :test_notice, payload: %{to: "alice"}}],
      projection_rows: [{:balance, "r1", :cash, 1_000}],
      context: %{actor: {:system, :scheduler}, correlation_id: "corr-" <> id, content_hash: nil, hall_ms: 24}
    }
  end

  # A second handle on the same authority epoch (another process of the same owner), with options.
  defp sibling(store, opts),
    do: PostgresEventStore.new(Repo, store.scope, [owner: store.owner, epoch: store.epoch] ++ opts)

  defp count(table), do: Repo.query!("select count(*) from #{table}").rows |> hd() |> hd()

  defp backend_pid, do: Repo.query!("select pg_backend_pid()").rows |> hd() |> hd()

  # A before-commit hook that reports the writer's backend, then holds the open transaction
  # (and every lock it took) until the test releases it.
  defp holding_hook(test, tag) do
    fn ->
      send(test, {tag, self(), backend_pid()})

      receive do
        {:release, ^tag} -> :ok
      end
    end
  end

  defp await_message(tag) do
    receive do
      {^tag, pid, backend} -> {pid, backend}
    after
      @guard_ms -> flunk("no #{inspect(tag)} message: the writer never reached its commit point")
    end
  end

  # Polls a boolean query until it holds, with a bounded number of attempts.
  defp await_db(description, sql, params, attempts \\ @poll_attempts)

  defp await_db(description, _sql, _params, 0), do: flunk("gave up waiting until #{description}")

  defp await_db(description, sql, params, attempts) do
    case Repo.query!(sql, params).rows do
      [[true]] -> :ok
      _ -> await_db(description, sql, params, attempts - 1)
    end
  end

  defp await_blocked(waiter, holder) do
    await_db(
      "backend #{waiter} waits on a lock held by backend #{holder}",
      "select $2::int = any(pg_blocking_pids($1::int))",
      [waiter, holder]
    )
  end

  defp await_backend_gone(backend) do
    await_db(
      "backend #{backend} has disconnected",
      "select not exists (select 1 from pg_stat_activity where pid = $1::int)",
      [backend]
    )
  end

  # Runs an append in its own process on one checked-out connection, reporting its backend first.
  defp async_append(store, request, tag) do
    test = self()

    Task.async(fn ->
      Repo.checkout(fn ->
        send(test, {tag, self(), backend_pid()})
        PostgresEventStore.append(store, request)
      end)
    end)
  end

  defp assert_no_trace_of_any_write do
    assert %{rows: [[0]]} = Repo.query!("select position from append_head")

    for table <- ~w(receipts batches events outbox restaurant_balances stream_heads) do
      assert count(table) == 0, "#{table} kept a row from a transaction that never committed"
    end
  end

  test "two writers from the same head: exactly one commits" do
    test = self()
    a = %{fresh_store() | hooks: %{before_commit: holding_hook(test, :a_locked), lost_reply: false, refuse: nil}}
    writer_a = Task.async(fn -> PostgresEventStore.append(a, request("a")) end)
    {_, a_backend} = await_message(:a_locked)

    # B waits on the head row A holds; a long lock timeout keeps it waiting rather than timing out.
    b = sibling(a, lock_timeout_ms: 60_000)
    writer_b = async_append(b, request("b"), :b_started)
    {_, b_backend} = await_message(:b_started)
    await_blocked(b_backend, a_backend)

    send(writer_a.pid, {:release, :a_locked})

    assert {:ok, _, 1} = Task.await(writer_a, @guard_ms)
    assert {:error, :conflict, _} = Task.await(writer_b, @guard_ms)

    assert %{rows: [[1, "a"]]} = Repo.query!("select position, command_id from batches")
    assert %{rows: [["a"]]} = Repo.query!("select command_id from receipts")
    assert %{rows: [["mail:a"]]} = Repo.query!("select dedupe_key from outbox")
    assert PostgresEventStore.head(a) == 1
    assert PostgresEventStore.stream_versions(a, "hall:h1") == %{hall: 1, control: 1}
  end

  test "killing the writer mid-transaction leaves nothing" do
    test = self()
    store = %{fresh_store() | hooks: %{before_commit: holding_hook(test, :locked), lost_reply: false, refuse: nil}}

    {writer, monitor} = spawn_monitor(fn -> PostgresEventStore.append(store, request("a")) end)
    {^writer, backend} = await_message(:locked)

    Process.exit(writer, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^writer, :killed} -> :ok
    after
      @guard_ms -> flunk("the writer was not killed")
    end

    # The pool disconnects a connection whose holder died, which ends the backend and rolls its
    # transaction back; wait for that rather than for any length of time.
    await_backend_gone(backend)

    assert_no_trace_of_any_write()
    assert PostgresEventStore.receipt(store, "a") == :none

    assert {:ok, _, 1} =
             PostgresEventStore.append(PostgresEventStore.new(Repo, store.scope, epoch: store.epoch), request("a"))

    assert count("batches") == 1
  end

  describe "a lost reply after commit" do
    defp env(id, command), do: %{command_id: id, actor: {:principal, "alice"}, command: command}

    defp purchase(qty),
      do: {:submit_purchase_request, %{restaurant_id: "r1", product: "rice_long", qty: qty, max_price_per_kunit: 1_000}}

    defp runtime do
      {:ok, rt} = Workflow.open(PostgresEventStore, fresh_store())

      init = {:initialize_hall, %{hall_id: "h1", catalog: MexicanFixture.catalog()}}
      {:accepted, _, rt} = Workflow.execute(rt, %{env("init", init) | actor: {:system, :admin}})

      create = {:create_restaurant, %{restaurant_id: "r1", stall_id: "s001", name: "Casa", cuisine: "mexican"}}
      {:accepted, _, rt} = Workflow.execute(rt, env("create", create))
      rt
    end

    defp assert_resolves_once(stuck, head) do
      assert {:error, :recovery_required, _} = Workflow.execute(stuck, env("buy-2", purchase(5)))

      assert {:committed, receipt, recovered} = Workflow.resolve(stuck, "buy-1")
      assert receipt.outcome == :accepted
      assert {:ok, ^receipt} = PostgresEventStore.receipt(recovered.store, "buy-1")
      assert recovered.position == head + 1
      assert PostgresEventStore.head(recovered.store) == head + 1
      assert %{rows: [[1]]} = Repo.query!("select count(*) from batches where command_id = 'buy-1'")

      assert {:replayed, ^receipt, _} = Workflow.execute(recovered, env("buy-1", purchase(100)))
      assert PostgresEventStore.head(recovered.store) == head + 1
    end

    test "resolves by the same command id" do
      rt = runtime()
      armed = %{rt | store: %{rt.store | hooks: %{rt.store.hooks | lost_reply: true}}}

      assert {:uncertain, "buy-1", stuck} = Workflow.execute(armed, env("buy-1", purchase(100)))
      assert_resolves_once(stuck, rt.position)
    end

    test "resolves by the same command id when the connection drops during COMMIT" do
      rt = runtime()
      dropping = %{rt | store: %{rt.store | repo: FeudHall.CommitDropRepo}}

      assert {:uncertain, "buy-1", stuck} = Workflow.execute(dropping, env("buy-1", purchase(100)))
      assert_resolves_once(%{stuck | store: %{stuck.store | repo: Repo}}, rt.position)
    end
  end

  test "a superseded owner cannot append" do
    base = PostgresEventStore.new(Repo, "hall:test")
    {:ok, a, 1} = PostgresEventStore.acquire_authority(base, "hall:test", "node-a")
    {:ok, _b, 2} = PostgresEventStore.acquire_authority(base, "hall:test", "node-b")

    assert {:error, :fenced, _} = PostgresEventStore.append(a, request())
    assert %{rows: [[0]]} = Repo.query!("select position from append_head")
    assert_no_trace_of_any_write()
  end

  test "a hung lock holder makes the next writer unavailable within lock_timeout" do
    test = self()
    a = %{fresh_store() | hooks: %{before_commit: holding_hook(test, :a_locked), lost_reply: false, refuse: nil}}
    writer_a = Task.async(fn -> PostgresEventStore.append(a, request("a")) end)
    {_, _a_backend} = await_message(:a_locked)

    b = sibling(a, lock_timeout_ms: 200)
    b_result = Task.await(Task.async(fn -> PostgresEventStore.append(b, request("b")) end), @guard_ms)
    assert {:error, :unavailable, _} = b_result

    # B's failure touched nothing of A's; once A stops hanging it still commits.
    send(writer_a.pid, {:release, :a_locked})
    assert {:ok, _, 1} = Task.await(writer_a, @guard_ms)
    assert %{rows: [["a"]]} = Repo.query!("select command_id from receipts")
  end

  test "the lock_timeout option applies only to the append's own transaction" do
    test = self()
    report = fn -> send(test, {:setting, Repo.query!("select current_setting('lock_timeout')").rows}) end
    store = sibling(fresh_store(), lock_timeout_ms: 200, hooks: %{before_commit: report})

    Repo.checkout(fn ->
      assert {:ok, _, 1} = PostgresEventStore.append(store, request())
      assert_received {:setting, [["200ms"]]}

      # Same connection, after the transaction: the pool-wide setting is back.
      assert %{rows: [["2s"]]} = Repo.query!("select current_setting('lock_timeout')")
    end)
  end
end
