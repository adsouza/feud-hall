# Launched by the Playwright fixture. Test controls are available only on stdin.
defmodule FeudHall.BrowserHall do
  alias FeudHall.Application.{CommandWorkflow, Recovery}
  alias FeudHall.Domain.Clock
  alias FeudHall.Domain.Content.{LaunchCatalog, SliceCatalog}
  alias FeudHall.Infrastructure.{HallAuthority, ManualClock, PostgresEventStore, Repo}
  alias FeudHall.Web.{Bootstrap, Diagnostics, Endpoint, Router, Token}

  @scope "browser"
  @authority FeudHall.LiveAuthority
  @restart_slot 19 * 3_600_000
  @restart_plan "npc:budget:#{@restart_slot}"

  def main(mode) do
    Application.load(:feud_hall)
    repo = Application.fetch_env!(:feud_hall, Repo)

    unless Mix.env() == :test and String.starts_with?(repo[:database], "feud_hall_browser_") and
             repo[:hostname] in ["localhost", "127.0.0.1"] and is_nil(repo[:url]) and
             not Application.get_env(:feud_hall, :serve, false) do
      raise "browser hall requires a disposable local test database"
    end

    {:ok, _} = Application.ensure_all_started(:feud_hall)
    Logger.configure(level: :info)

    case mode do
      ["seed-restart"] -> seed_restart()
      [] -> serve()
    end
  end

  def emit(_, record), do: Diagnostics.export([record])

  defp serve do
    {:ok, clock} = ManualClock.start_link()
    secret = System.fetch_env!("FEUD_HALL_BROWSER_SECRET")

    Application.put_env(:feud_hall, Token, secret: secret)

    {:ok, _} =
      HallAuthority.start_link(
        name: @authority,
        scope: @scope,
        owner: owner(),
        store_mod: PostgresEventStore,
        store: store(),
        clock: {ManualClock, clock},
        diagnostics: {__MODULE__, nil},
        tick_ms: :manual,
        max_gap_ms: 3_600_000
      )

    if hall() == nil do
      execute("browser-init", {:system, :admin}, :initialize_hall, init_payload())
      advance(clock, Clock.service_ms(6 * Clock.hour()) + 10_000)
      # The first plan placed purchase requests at the end of the tick.
      advance(clock, 10_000)
    end

    {:ok, _} = Bootstrap.start_link(@scope, catalog())

    {:ok, _} =
      Endpoint.start_link(
        adapter: Bandit.PhoenixAdapter,
        http: [ip: {127, 0, 0, 1}, port: 0],
        pubsub_server: FeudHall.PubSub,
        secret_key_base: :crypto.hash(:sha512, secret) |> Base.encode64(),
        server: true
      )

    {:ok, {_ip, port}} = Endpoint.server_info(:http)
    origin = "http://127.0.0.1:#{port}"
    Application.put_env(:feud_hall, Router, origin: origin, admin_key: secret)
    respond(%{origin: origin})

    for line <- IO.stream(:stdio, :line) do
      line |> Jason.decode!() |> control(clock) |> respond()
    end
  end

  defp seed_restart do
    {:ok, rt, _} = Recovery.recover(PostgresEventStore, store(), owner(), scope: @scope)
    rt = commit(rt, "browser-init", {:system, :admin}, :initialize_hall, init_payload())

    rt =
      commit(rt, "npc:budget:create", {:npc, "budget"}, :create_restaurant, %{
        restaurant_id: "npc-budget",
        stall_id: "s001",
        name: "NPC budget",
        cuisine: "levantine"
      })

    # Leave the 19:00 NPC plan due at the durable head. The next VM's authority
    # must recover it before it can open the real HTTP listener.
    rt =
      commit(rt, "tick:browser-restart", {:system, :scheduler}, :advance_clock, %{
        to_service_ms: Clock.service_ms(@restart_slot)
      })

    respond(%{position: rt.position})
  end

  defp control(%{"advance_to" => at}, clock) when is_integer(at) do
    advance(clock, max(0, Clock.service_ms(at + Clock.ratio() - 1) - Clock.service_ms(hall().now)))
    %{now: hall().now}
  end

  defp control(%{"ready_order" => label}, clock) when label in ["first", "second"] do
    execute("browser-diner-#{label}", {:system, :demand}, :admit_visit, %{
      source: :simulated,
      diner_id: label,
      stall_id: "s001",
      main: "falafel_wrap",
      profile_id: "unrestricted",
      budget: 2_000
    })

    selection = await_selection(clock, 48)
    %{deadline: selection.deadline}
  end

  defp control(%{"restart_plan" => true}, _clock) do
    {PostgresEventStore, handle} = HallAuthority.store(@authority)
    {:ok, %{position: position, outcome: :accepted}} = PostgresEventStore.receipt(handle, @restart_plan)
    {:ok, [%{command_id: @restart_plan, events: events} | _]} = PostgresEventStore.read_from(handle, position - 1)
    %{type: :npc_planned, outcomes: outcomes} = Enum.find(events, &(&1.type == :npc_planned))
    %{position: position, outcomes: outcomes}
  end

  defp await_selection(clock, remaining) do
    case hall().management.selections["s001"] do
      nil when remaining > 0 ->
        advance(clock, 250)
        await_selection(clock, remaining - 1)

      %{} = selection ->
        selection
    end
  end

  defp advance(clock, ms) do
    ManualClock.advance(clock, ms)
    :ok = HallAuthority.tick(@authority)
  end

  defp execute(id, actor, kind, payload) do
    {:accepted, _} = HallAuthority.execute(@authority, envelope(id, actor, kind, payload))
  end

  defp commit(rt, id, actor, kind, payload) do
    {:accepted, _, rt} = CommandWorkflow.execute(rt, envelope(id, actor, kind, payload))
    rt
  end

  defp init_payload,
    do: %{hall_id: @scope, managed: true, catalog: FeudHall.Fixtures.quiet_catalog(catalog())}

  defp catalog do
    if System.get_env("FEUD_HALL_BROWSER_LAUNCH") == "1", do: LaunchCatalog.catalog(), else: SliceCatalog.catalog()
  end

  defp envelope(id, actor, kind, payload), do: %{command_id: id, actor: actor, command: {kind, payload}}
  defp hall, do: HallAuthority.state(@authority).hall
  defp store, do: PostgresEventStore.new(Repo, @scope)
  defp owner, do: "browser-#{System.pid()}"
  defp respond(value), do: IO.puts("BROWSER_HALL " <> Jason.encode!(value))
end

FeudHall.BrowserHall.main(System.argv())
