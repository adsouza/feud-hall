defmodule FeudHall.Web.EndpointTest do
  use ExUnit.Case, async: false

  alias FeudHall.Domain.Content.{LaunchCatalog, Tuning}
  alias FeudHall.Infrastructure.{HallAuthority, InMemoryEventStore, ManualClock}
  alias FeudHall.Web.{Endpoint, ErrorJSON, Router}

  # A test-only operator secret, at least the 32 bytes the router requires.
  @secret String.duplicate("k", 32)

  test "the endpoint sends a JSON error for malformed request bodies" do
    start_supervised!({Endpoint, server: false})

    conn =
      Plug.Test.conn(:post, "/api/commands", "{")
      |> Plug.Conn.put_req_header("content-type", "application/json")

    assert_raise Plug.Parsers.ParseError, fn -> Endpoint.call(conn, []) end
    assert {400, _, body} = Plug.Test.sent_resp(conn)
    assert Jason.decode!(body) == %{"error" => "invalid_command"}
  end

  test "unexpected server failures report unavailability without exposing details" do
    assert ErrorJSON.render("500.json", %{status: 500, reason: "private failure details"}) ==
             %{error: :unavailable}
  end

  describe "POST /api/operator/retune" do
    setup do
      previous = Application.fetch_env(:feud_hall, Router)
      Application.put_env(:feud_hall, Router, origin: "http://localhost", admin_key: @secret)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:feud_hall, Router, value)
          :error -> Application.delete_env(:feud_hall, Router)
        end
      end)

      start_supervised!({Endpoint, server: false})
      {:ok, clock} = start_supervised({ManualClock, 0})

      pid =
        start_supervised!(
          {HallAuthority,
           name: FeudHall.LiveAuthority,
           store_mod: InMemoryEventStore,
           store: InMemoryEventStore.new(),
           owner: "node-a",
           scope: "hall:test",
           clock: {ManualClock, clock},
           tick_ms: :manual}
        )

      init = %{hall_id: "h1", catalog: LaunchCatalog.catalog(), managed: true}

      assert {:accepted, _} =
               HallAuthority.execute(pid, %{
                 command_id: "init",
                 actor: {:system, :admin},
                 command: {:initialize_hall, init}
               })

      %{pid: pid}
    end

    defp retune(body, secret \\ @secret) do
      conn =
        Plug.Test.conn(:post, "/api/operator/retune", Jason.encode!(body))
        |> Plug.Conn.put_req_header("content-type", "application/json")

      conn = if secret, do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> secret), else: conn
      conn = Endpoint.call(conn, [])
      {conn.status, Jason.decode!(conn.resp_body)}
    end

    defp version(pid), do: Tuning.of(HallAuthority.state(pid).hall.catalog).version

    defp retune_events(pid) do
      {mod, store} = HallAuthority.store(pid)
      {:ok, batches} = mod.read_from(store, 0)
      for %{events: events} <- batches, %{type: :hall_rules_retuned} = e <- events, do: e
    end

    test "an operator applies the chosen tuning once", %{pid: pid} do
      chosen = Tuning.chosen().version
      assert version(pid) == 1
      body = %{command_id: "operator-retune:#{chosen}", version: chosen}

      assert {200, %{"accepted" => true, "command_id" => "operator-retune:2"}} = retune(body)
      assert version(pid) == chosen
      assert [_] = retune_events(pid)

      # The same request again returns the original receipt and records nothing.
      assert {200, %{"accepted" => true}} = retune(body)
      assert [_] = retune_events(pid)

      # A different command ID is a new attempt, which the hall refuses.
      assert {200, %{"accepted" => false, "reason" => "retune_unavailable"}} =
               retune(%{body | command_id: "operator-retune:again"})

      assert [_] = retune_events(pid)
    end

    test "retune needs the operator secret and the chosen version", %{pid: pid} do
      body = %{command_id: "operator-retune:x", version: Tuning.chosen().version}

      assert {403, %{"error" => "forbidden"}} = retune(body, nil)
      assert {403, %{"error" => "forbidden"}} = retune(body, String.duplicate("w", 32))
      assert {403, %{"error" => "forbidden"}} = retune(body, "short")

      for wrong <- [3, 1, "2", nil, 2.0] do
        assert {422, %{"error" => "unknown_tuning_version"}} = retune(%{body | version: wrong})
      end

      assert {422, %{"error" => "unknown_tuning_version"}} = retune(%{command_id: "operator-retune:x"})
      assert {403, %{"error" => "forbidden"}} = retune(%{version: 2})
      assert {403, %{"error" => "forbidden"}} = retune(%{command_id: 7, version: 2})

      assert version(pid) == 1
      assert retune_events(pid) == []
      assert :none = receipt(pid, "operator-retune:x")
    end

    defp receipt(pid, id) do
      {mod, store} = HallAuthority.store(pid)
      mod.receipt(store, id)
    end

    defp seed(body, secret) do
      conn =
        Plug.Test.conn(:post, "/api/operator/seed", Jason.encode!(body))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> secret)

      conn = Endpoint.call(conn, [])
      {conn.status, Jason.decode!(conn.resp_body)}
    end

    defp head(pid) do
      {mod, store} = HallAuthority.store(pid)
      mod.head(store)
    end

    # Runs `fun` with the operator key configured as `key`, then puts the test's key back.
    defp with_admin_key(key, fun) do
      env = Application.fetch_env!(:feud_hall, Router)
      Application.put_env(:feud_hall, Router, Keyword.put(env, :admin_key, key))

      try do
        fun.()
      after
        Application.put_env(:feud_hall, Router, env)
      end
    end

    # A key that is unset, empty or shorter than 32 bytes opens neither operator route, even
    # to a request that presents exactly that key.
    for {label, key, bearer} <- [
          {"unset", nil, ""},
          {"empty", "", ""},
          {"31 bytes long", String.duplicate("k", 31), String.duplicate("k", 31)}
        ] do
      test "a configured operator key that is #{label} opens neither operator route", %{pid: pid} do
        key = unquote(key)
        bearer = unquote(bearer)
        before = head(pid)
        retune_body = %{command_id: "upgrade:retune-2", version: Tuning.chosen().version}
        seed_body = %{command_id: "operator-seed:x", principal: "p1"}

        with_admin_key(key, fn ->
          assert Application.fetch_env!(:feud_hall, Router)[:admin_key] == key
          assert {403, %{"error" => "forbidden"}} = retune(retune_body, bearer)
          assert {403, %{"error" => "forbidden"}} = seed(seed_body, bearer)
        end)

        assert Application.fetch_env!(:feud_hall, Router)[:admin_key] == @secret
        assert head(pid) == before
        assert version(pid) == 1
        assert retune_events(pid) == []
        assert :none = receipt(pid, "upgrade:retune-2")
        assert :none = receipt(pid, "operator-seed:x")

        # The same two requests are accepted once a full-length key is configured and presented,
        # so the refusals above were for the key alone.
        assert {200, %{"accepted" => true}} = retune(retune_body)
        assert {200, %{"accepted" => _}} = seed(seed_body, @secret)
        assert {:ok, _} = receipt(pid, "operator-seed:x")
      end
    end

    test "the documented command ID is reserved: no device can spend it before the operator", %{pid: pid} do
      id = "upgrade:retune-2"
      guest = {:bootstrap_guest, %{name: "Early Bird"}}
      before = head(pid)

      assert {:error, :reserved_command_id} =
               HallAuthority.management_execute(pid, "device-1", %{command_id: id, command: guest})

      assert head(pid) == before
      assert :none = receipt(pid, id)

      assert {200, %{"accepted" => true, "command_id" => ^id}} =
               retune(%{command_id: id, version: Tuning.chosen().version})

      assert version(pid) == Tuning.chosen().version
      assert [_] = retune_events(pid)

      # An ID outside the reserved prefixes has no such protection: a device that spends it
      # first leaves the operator's request with that ID unable to apply anything.
      {:ok, clock} = start_supervised({ManualClock, 0}, id: :second_clock)

      other =
        start_supervised!(
          {HallAuthority,
           name: :second_hall,
           store_mod: InMemoryEventStore,
           store: InMemoryEventStore.new(),
           owner: "node-b",
           scope: "hall:second",
           clock: {ManualClock, clock},
           tick_ms: :manual},
          id: :second_hall
        )

      init = %{hall_id: "h2", catalog: LaunchCatalog.catalog(), managed: true}

      assert {:accepted, _} =
               HallAuthority.execute(other, %{
                 command_id: "init",
                 actor: {:system, :admin},
                 command: {:initialize_hall, init}
               })

      open_id = "operator-retune:2"

      assert {:accepted, _} =
               HallAuthority.management_execute(other, "device-1", %{command_id: open_id, command: guest})

      refute match?(
               {:accepted, _},
               HallAuthority.execute(other, %{
                 command_id: open_id,
                 actor: {:system, :admin},
                 command: {:retune_rules, %{tuning: Tuning.chosen()}}
               })
             )

      assert Tuning.of(HallAuthority.state(other).hall.catalog).version == 1
    end
  end
end
