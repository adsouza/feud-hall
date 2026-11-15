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
  end
end
