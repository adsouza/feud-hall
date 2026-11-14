# Run with the disposable launcher in peak_sessions.py.
defmodule FeudHall.PeakSessions do
  alias FeudHall.Domain.{Clock, Identity}
  alias FeudHall.Domain.Content.LaunchCatalog
  alias FeudHall.Domain.Hall.Management, as: HallManagement
  alias FeudHall.Infrastructure.{HallAuthority, PostgresEventStore, Repo}
  alias FeudHall.Web.{Endpoint, Router, Token}

  @authority FeudHall.LiveAuthority
  @scope "peak-sessions"
  @sessions_per_role 150

  defmodule ManualTime do
    def now_ms(ref), do: :atomics.get(ref, 1)
  end

  def run(output, scenario) when scenario in ["owners", "expanded"] do
    :ok = prepare_database!()
    clock = :atomics.new(1, [])
    secret = :crypto.strong_rand_bytes(48) |> Base.encode64()
    Application.put_env(:feud_hall, Token, secret: secret)

    {:ok, authority} =
      HallAuthority.start_link(
        name: @authority,
        scope: @scope,
        store_mod: PostgresEventStore,
        store: PostgresEventStore.new(Repo, @scope),
        clock: {ManualTime, clock},
        tick_ms: :manual,
        max_gap_ms: Clock.service_ms(Clock.day())
      )

    admin("init", :initialize_hall, %{hall_id: @scope, catalog: catalog(), managed: true})
    admin("visitor-play", :enable_visitor_play, %{})
    group_size = if scenario == "expanded", do: 3, else: 1
    owners = 1..@sessions_per_role |> Enum.chunk_every(group_size) |> Enum.flat_map(&open_venture/1)
    minutes = if group_size == 3, do: 25, else: 20
    :atomics.put(clock, 1, Clock.service_ms(minutes * Clock.minute()))
    :ok = HallAuthority.tick(authority)

    Enum.each(owners, fn owner ->
      client(owner.device, "attend:#{owner.stall}", :report_owner_presence, %{present: true})
      client(owner.device, "open:#{owner.stall}", :open_stall, %{stall_id: owner.stall})
    end)

    helpers =
      Enum.map(owners, fn owner ->
        helper = register("helper", owner.index)
        assert_offer_and_accept(helper, owner.stall)
      end)

    diners = Enum.map(owners, &admit_diner/1)
    true = map_size(state().stalls) == @sessions_per_role
    true = map_size(state().management.shift_by_principal) == @sessions_per_role
    true = map_size(state().visits) == @sessions_per_role

    {:ok, _} =
      Endpoint.start_link(
        adapter: Bandit.PhoenixAdapter,
        http: [ip: {127, 0, 0, 1}, port: 0],
        pubsub_server: FeudHall.PubSub,
        secret_key_base: secret,
        server: true
      )

    {:ok, {_ip, port}} = Endpoint.server_info(:http)
    origin = "http://127.0.0.1:#{port}"
    Application.put_env(:feud_hall, Router, origin: origin)
    position = HallAuthority.state(authority).position
    sessions = owners ++ diners ++ helpers
    IO.puts("Seeded 150 occupied stalls, 150 paid shifts and 150 funded guest visits at batch #{position}.")

    results =
      for round <- 1..3 do
        peak_round(origin, sessions, round)
      end

    report = %{
      sessions: length(sessions),
      stalls: @sessions_per_role,
      phase: scenario,
      owner_principals: div(@sessions_per_role, group_size),
      rounds: results,
      revision: System.fetch_env!("FEUD_HALL_PEAK_REVISION"),
      hall_position: position
    }

    File.write!(output, Jason.encode!(report))
  end

  defp prepare_database! do
    database = System.fetch_env!("FEUD_HALL_PEAK_DATABASE")
    true = Regex.match?(~r/^feud_hall_peak_[a-z0-9_]+$/, database)
    nil = System.get_env("DATABASE_URL")
    true = System.get_env("FEUD_HALL_SERVE") != "1"
    config = Application.fetch_env!(:feud_hall, Repo)
    true = config[:hostname] in ["localhost", "127.0.0.1"]
    Application.put_env(:feud_hall, Repo, Keyword.merge(config, database: database, log: false))
    Logger.configure(level: :warning)
    {:ok, _} = Application.ensure_all_started(:feud_hall)

    %{rows: [[^database, 0]]} =
      Repo.query!("select current_database(), count(*) from pg_tables where schemaname = 'public'")

    _versions = Ecto.Migrator.run(Repo, :up, all: true, log: false)
    :ok
  end

  defp catalog do
    catalog = LaunchCatalog.catalog()
    caps = Map.new(catalog.rules.market.replenish_cap, fn {product, cap} -> {product, cap * 50} end)

    %{catalog | npc_profiles: []}
    |> put_in([:rules, :demand, :arrivals_per_equivalent], 0)
    |> put_in([:rules, :demand, :equivalent_floor_millis], @sessions_per_role * 1_000)
    |> put_in([:rules, :market, :replenish_cap], caps)
  end

  defp open_venture([primary | expansions]) do
    owner = register("owner", primary)
    stall = stall_id(primary)
    restaurant = "peak-r-#{primary}"
    starters = state().catalog.recipes |> Map.values() |> Enum.filter(& &1.starter) |> Enum.sort_by(& &1.cuisine)
    starter = Enum.at(starters, rem(primary - 1, length(starters)))
    admin("license:#{primary}", :seed_owner, %{principal: owner.principal, reviewer?: false})
    client(owner.device, "reserve", :reserve_stall, %{stall_id: stall})

    client(owner.device, "lease", :create_restaurant, %{
      stall_id: stall,
      restaurant_id: restaurant,
      cuisine: starter.cuisine,
      name: "Peak Kitchen #{primary}"
    })

    for index <- expansions do
      client(owner.device, "expansion:#{index}", :lease_location, %{
        stall_id: stall_id(index),
        restaurant_id: restaurant,
        cuisine: starter.cuisine
      })
    end

    # One normal order for six portions is enough for the three locations
    # because they really share a single stock ledger.
    client(owner.device, "stock", :request_starter_stock, %{stall_id: stall, restaurant_id: restaurant, budget: 500_000})

    for index <- [primary | expansions] do
      sid = stall_id(index)
      client(owner.device, "helpers:#{index}", :set_helper_offers, %{stall_id: sid, enabled: true})

      client(owner.device, "price:#{index}", :set_menu_price, %{
        stall_id: sid,
        restaurant_id: restaurant,
        recipe_id: starter.id,
        price: 900
      })

      if rem(index, 3) == 0 do
        client(owner.device, "unattended:#{index}", :set_unattended_policy, %{
          stall_id: sid,
          enabled: true,
          cash_floor: 0
        })
      end

      Map.merge(owner, %{index: index, stall: sid, restaurant: restaurant, starter: starter.id})
    end
  end

  # The room rule refuses a spot in a room that is not open yet, and room k+1
  # opens only when every spot of one class in rooms 1..k is leased. Leasing
  # the quiet spots first, in ascending ID order, fills each room's four quiet
  # corners before the next room's, so the ten rooms open in a chain; every
  # other spot is then in an open room. Index i (1-based) takes the i-th spot of
  # that order. For the launch layout this is s001..s150, because the quiet
  # class is s001..s040.
  defp stall_id(index), do: Enum.at(lease_order(), index - 1)

  defp lease_order do
    {quiet, rest} = state().catalog.layout |> Enum.sort_by(& &1.slot_id) |> Enum.split_with(&(&1.tier == :quiet))
    Enum.map(quiet ++ rest, & &1.slot_id)
  end

  defp admit_diner(owner) do
    diner = register("diner", owner.index)
    client(diner.device, "allowance", :request_allowance)
    request = %{stall_id: owner.stall, main: owner.starter, profile_id: "unrestricted"}
    {:ok, %{terms: terms}} = HallAuthority.management_quote(@authority, diner.device, request)

    confirmed =
      update_in(terms.components, fn components ->
        Enum.map(components, &Map.update!(&1, :price, fn price -> String.to_integer(price) end))
      end)

    client(diner.device, "order", :admit_visit, Map.put(request, :confirmed, confirmed))
    Map.put(diner, :stall, owner.stall)
  end

  defp assert_offer_and_accept(helper, stall) do
    {:ok, offer} = HallManagement.shift_offer(state(), stall, helper.principal)
    client(helper.device, "shift", :accept_helper_shift, Map.take(offer, [:stall_id, :rate, :quoted_at, :expires_at]))
    Map.put(helper, :stall, stall)
  end

  defp register(role, index) do
    device = "#{role}:#{index}"
    client(device, "register", :bootstrap_guest, %{name: "#{role} #{index}"})
    control = HallAuthority.state(@authority).control
    principal = Identity.principal_for_device(Identity.get(control), device)
    %{device: device, principal: principal, index: index, role: role}
  end

  defp client(device, suffix, kind, payload \\ %{}) do
    {:accepted, _} =
      HallAuthority.management_execute(@authority, device, %{
        command_id: "#{device}:#{suffix}",
        command: {kind, payload}
      })
  end

  defp admin(id, kind, payload) do
    {:accepted, _} =
      HallAuthority.execute(@authority, %{
        command_id: id,
        actor: {:system, :admin},
        command: {kind, payload}
      })
  end

  defp state, do: HallAuthority.state(@authority).hall

  defp peak_round(origin, sessions, round) do
    # Establish connections before releasing the burst. This measures live
    # sessions rather than the host's TCP SYN backlog.
    connected = Enum.map(sessions, &{&1, connect(origin)})
    start = System.monotonic_time(:millisecond)

    commands =
      if round == 1 do
        sessions
        |> Enum.filter(&(&1.role == "owner"))
        |> Enum.take(30)
        |> Enum.map(&{&1, connect(origin)})
        |> Task.async_stream(fn {session, socket} -> heartbeat(origin, session, socket) end,
          max_concurrency: 30,
          timeout: 30_000,
          ordered: false
        )
      else
        []
      end

    # Start the independent command sample before draining the simultaneously issued reads.
    writes = Task.async(fn -> Enum.map(commands, fn {:ok, result} -> result end) end)

    reads =
      connected
      |> Task.async_stream(fn {session, socket} -> query(origin, session, socket) end,
        max_concurrency: length(sessions),
        timeout: 30_000,
        ordered: false
      )
      |> Enum.map(fn {:ok, ms} -> ms end)

    result = %{
      round: round,
      state_ms: distribution(reads),
      heartbeat_ms: distribution(Task.await(writes, 30_000)),
      wall_ms: System.monotonic_time(:millisecond) - start
    }

    IO.puts("Round #{round}: #{Jason.encode!(result)}")
    result
  end

  defp query(origin, session, socket) do
    {ms, response} = timed(fn -> request(socket, :get, origin <> "/api/state", session, nil) end)
    %{"profile" => profile} = Jason.decode!(response)
    true = profile["account"]["id"] == session.principal

    case session.role do
      "owner" -> true = profile["restaurant"]["id"] == session.restaurant
      "diner" -> true = profile["visit"]["stall"] == session.stall
      "helper" -> true = profile["work"]["active"]["stall_id"] == session.stall
    end

    ms
  end

  defp heartbeat(origin, session, socket) do
    payload = %{command_id: "peak-heartbeat:#{session.index}", kind: "report_owner_presence", payload: %{present: true}}
    {ms, response} = timed(fn -> request(socket, :post, origin <> "/api/commands", session, payload) end)
    %{"accepted" => true} = Jason.decode!(response)
    ms
  end

  defp connect(origin) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, URI.parse(origin).port, [:binary, active: false], 5_000)
    socket
  end

  defp request(socket, method, url, session, payload) do
    uri = URI.parse(url)
    origin = URI.to_string(%{uri | path: nil})
    token = Token.sign(:device, session.device)

    try do
      body = if payload, do: Jason.encode!(payload), else: ""
      method = method |> Atom.to_string() |> String.upcase()

      headers = [
        method,
        " ",
        uri.path,
        " HTTP/1.1\r\n",
        "Host: 127.0.0.1:",
        Integer.to_string(uri.port),
        "\r\nConnection: close\r\n",
        "x-feud-protocol: 1\r\nCookie: _feud_device=",
        token,
        "\r\n"
      ]

      post_headers =
        if payload,
          do: [
            "Origin: ",
            origin,
            "\r\nx-feud-command: 1\r\nContent-Type: application/json\r\n",
            "Content-Length: ",
            Integer.to_string(byte_size(body)),
            "\r\n"
          ],
          else: []

      :ok = :gen_tcp.send(socket, [headers, post_headers, "\r\n", body])
      response = recv(socket, [])
      [headers, body] = :binary.split(response, "\r\n\r\n")
      true = String.starts_with?(headers, "HTTP/1.1 200 ")
      body
    after
      :gen_tcp.close(socket)
    end
  end

  defp recv(socket, chunks) do
    case :gen_tcp.recv(socket, 0, 25_000) do
      {:ok, bytes} -> recv(socket, [bytes | chunks])
      {:error, :closed} -> chunks |> Enum.reverse() |> IO.iodata_to_binary()
      {:error, error} -> raise "Peak HTTP receive failed: #{error}"
    end
  end

  defp timed(fun) do
    {us, result} = :timer.tc(fun)
    {Float.round(us / 1000, 2), result}
  end

  defp distribution([]), do: %{count: 0}

  defp distribution(samples) do
    sorted = Enum.sort(samples)
    size = length(samples)
    percentile = fn pct -> Enum.at(sorted, Integer.ceil_div(size * pct, 100) - 1) end
    %{count: size, p50: percentile.(50), p95: percentile.(95), p99: percentile.(99), max: List.last(sorted)}
  end
end

[output, scenario] = System.argv()
FeudHall.PeakSessions.run(output, scenario)
