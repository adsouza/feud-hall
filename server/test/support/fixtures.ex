defmodule FeudHall.Fixtures do
  @moduledoc "Deterministic hall setups for focused tests."

  import ExUnit.Assertions

  alias FeudHall.Domain.{Clock, Hall, Offers}
  alias FeudHall.Domain.Content.SliceCatalog

  @stall "s001"

  def ctx(actor, id), do: %{command_id: id, actor: actor}

  @doc """
  `catalog` with no simulated arrivals (zero arrivals per equivalent), for
  tests about something other than demand: no diner buys food, takes stock or
  queues unless the test admits one. The midnight forecast still runs.
  """
  def quiet_catalog(catalog \\ SliceCatalog.catalog()),
    do: put_in(catalog, [:rules, :demand, :arrivals_per_equivalent], 0)

  def owner(id \\ "alice"), do: {:principal, id}

  @doc "Runs a command that must succeed; returns `{state, events}`."
  def run!({state, log}, command, actor, id) do
    case Hall.execute(state, command, ctx(actor, id)) do
      {:ok, state, events} -> {state, log ++ events}
      {:error, reason} -> flunk("#{inspect(elem(command, 0))} rejected: #{inspect(reason)}")
    end
  end

  @doc "Runs a command that must be rejected without effects; returns the reason."
  def reject!({state, _log}, command, actor, id) do
    assert {:error, reason} = Hall.decide(state, command, ctx(actor, id))
    reason
  end

  def advance(world, service_ms, id \\ nil) do
    run!(world, {:advance_clock, %{to_service_ms: service_ms}}, {:system, :scheduler}, id || "adv#{service_ms}")
  end

  @doc "Advances to an exact hall-time instant (must be a multiple of 24 ms)."
  def advance_hall(world, hall_ms) do
    0 = rem(hall_ms, Clock.ratio())
    advance(world, div(hall_ms, Clock.ratio()), "advh#{hall_ms}")
  end

  @doc """
  A hall with alice's open restaurant fully unlocked and stocked. The stock is
  bought through purchase requests filled at the first market clearing (hall
  time `clear_every_hall_ms`), so a stocked world starts at that instant; with
  `stock: %{}` nothing is bought and the hall stays at time 0. Simulated
  diners arrive as the catalog's demand rules say; `arrivals: false` uses
  `quiet_catalog/1` instead.
  """
  def stocked_world(opts \\ []) do
    world =
      opts
      |> stocked_world_steps()
      |> Enum.reduce({nil, []}, fn step, {state, _log} = world ->
        {command, actor, id} = step.(state)
        run!(world, command, actor, id)
      end)

    assert_filled!(world, Keyword.get(opts, :stock, default_stock()))
  end

  @doc """
  The commands `stocked_world/1` runs, in order. Each step is a function of the
  state reached so far returning `{command, actor, command_id}`, so callers that
  record or replay the setup (the trace properties) issue exactly the same
  commands and IDs.
  """
  def stocked_world_steps(opts \\ []) do
    catalog = Keyword.get(opts, :catalog, SliceCatalog.catalog())
    catalog = if Keyword.get(opts, :arrivals, true), do: catalog, else: quiet_catalog(catalog)
    fixed = fn command, actor, id -> fn _state -> {command, actor, id} end end

    unlocks =
      if Keyword.get(opts, :unlock, true) do
        Enum.flat_map(~w(chicken_tacos vegetable_quesadilla arroz_con_leche horchata), fn recipe ->
          [
            fixed.({:unlock_recipe, %{restaurant_id: "r1", recipe_id: recipe}}, owner(), "unlock-" <> recipe),
            fixed.(
              {:set_menu_price,
               %{restaurant_id: "r1", recipe_id: recipe, price: catalog.recipes[recipe].suggested_price}},
              owner(),
              "price-" <> recipe
            )
          ]
        end)
      else
        []
      end

    purchases =
      opts
      |> Keyword.get(:stock, default_stock())
      |> Enum.sort()
      |> Enum.map(fn {product, qty} ->
        fn state -> {purchase(product, qty), owner(), "buy-#{product}-#{state.now}"} end
      end)

    purchases = if purchases == [], do: [], else: purchases ++ [&clearing_step/1]

    [
      fixed.({:initialize_hall, %{hall_id: "hall-1", catalog: catalog}}, {:system, :admin}, "init"),
      fixed.(
        {:create_restaurant, %{restaurant_id: "r1", stall_id: @stall, name: "Casa Alice", cuisine: "mexican"}},
        owner(),
        "create"
      )
    ] ++ unlocks ++ purchases ++ [fixed.({:open_stall, %{stall_id: @stall}}, owner(), "open")]
  end

  @doc "The default stock: every quantity fits in the market's opening stock."
  def default_stock do
    %{
      "corn_tortilla" => 40,
      "black_beans_dried" => 1_200,
      "salsa_roja" => 1_200,
      "salsa_verde" => 800,
      "onion" => 600,
      "cilantro" => 200,
      "chicken_thigh" => 1_200,
      "flour_tortilla" => 20,
      "queso_oaxaca" => 1_000,
      "peppers" => 1_000,
      "rice_long" => 1_000,
      "milk_whole" => 3_000,
      "sugar" => 1_000,
      "cinnamon" => 50,
      "filtered_water" => 5_000
    }
  end

  @doc """
  Submits one purchase request per product, advances to the next market
  clearing, and asserts every request was filled in full.
  """
  def stock(world, stock) do
    stock
    |> Enum.sort()
    |> Enum.reduce(world, fn {product, qty}, w ->
      run!(w, purchase(product, qty), owner(), "buy-#{product}-#{elem(w, 0).now}")
    end)
    |> to_clearing()
    |> assert_filled!(stock)
  end

  @doc "Like `stock/2` for one product under command ID `id`."
  def buy(world, product, qty, id) do
    world
    |> run!(purchase(product, qty), owner(), id)
    |> to_clearing()
    |> assert_filled!(%{product => qty})
  end

  @doc "Advances to the next market clearing."
  def to_clearing({state, _} = world) do
    {command, actor, id} = clearing_step(state)
    run!(world, command, actor, id)
  end

  defp clearing_step(state) do
    at = state.market.next_clear_at
    {{:advance_clock, %{to_service_ms: div(at, Clock.ratio())}}, {:system, :scheduler}, "clear#{at}"}
  end

  # The last clearing in the log filled each product's request in full.
  defp assert_filled!({_state, log} = world, stock) do
    if stock != %{} do
      %{fills: fills, unfilled: unfilled} = log |> Enum.filter(&(&1.type == :market_cleared)) |> List.last()

      for {product, qty} <- stock do
        filled = for %{restaurant_id: "r1", product: ^product, qty: q} <- fills, do: q
        assert Enum.sum(filled) == qty, "#{product}: filled #{inspect(filled)} of #{qty}; unfilled #{inspect(unfilled)}"
      end
    end

    world
  end

  defp purchase(product, qty),
    do:
      {:submit_purchase_request, %{restaurant_id: "r1", product: product, qty: qty, max_price_per_kunit: 1_000_000_000}}

  def simulated_visit(world, id, main, drink \\ nil, profile \\ "unrestricted", budget \\ 10_000) do
    run!(
      world,
      {:admit_visit,
       %{
         source: :simulated,
         diner_id: id,
         budget: budget,
         stall_id: @stall,
         main: main,
         drink: drink,
         profile_id: profile
       }},
      {:system, :demand},
      "visit-" <> id
    )
  end

  @doc "Quotes and confirms a guest tray in one step."
  def guest_visit(world, guest, id, main, drink \\ nil, profile \\ "unrestricted") do
    {state, _} = world
    {:ok, requirement} = FeudHall.Domain.Dietary.requirement(state.catalog, profile)
    blank = %{requirement: requirement, carbs_reserved: 0, carbs_served: 0}
    {:ok, quote} = Offers.quote_tray(state, @stall, main, drink, blank)

    run!(
      world,
      {:admit_visit,
       %{
         source: :guest,
         stall_id: @stall,
         main: main,
         drink: drink,
         profile_id: profile,
         confirmed: Offers.terms(quote)
       }},
      {:principal, guest},
      id
    )
  end

  def grant(world, guest, amount, id),
    do: run!(world, {:grant_allowance, %{principal: guest, amount: amount}}, {:system, :visitor_fund}, id)

  @doc """
  Lets the automatic kitchen serve an accepted tray: advances hall time to
  its `estimated_completion` (on a scheduler tick) and asserts it was served.
  """
  def serve_tray(world, tray_id) do
    {state, _} = world
    world = advance_hall(world, ceil_to_tick(state.trays[tray_id].estimated_completion))
    assert elem(world, 0).trays[tray_id].status == :served, "tray #{tray_id} was not served"
    world
  end

  @doc "Like `serve_tray/2` for an accepted dessert order."
  def serve_dessert(world, order_id) do
    {state, _} = world
    world = advance_hall(world, ceil_to_tick(state.orders[order_id].estimated_completion))
    assert elem(world, 0).orders[order_id].status == :served, "dessert #{order_id} was not served"
    world
  end

  def ceil_to_tick(hall_ms), do: div(hall_ms + Clock.ratio() - 1, Clock.ratio()) * Clock.ratio()

  def tray_id(id), do: "T:" <> id
  def visit_id(id), do: "V:" <> id
end
