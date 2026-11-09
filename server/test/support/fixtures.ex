defmodule FeudHall.Fixtures do
  @moduledoc "Deterministic hall setups for focused tests."

  import ExUnit.Assertions

  alias FeudHall.Domain.{Clock, Hall, Offers}
  alias FeudHall.Domain.Content.SliceCatalog

  @stall "s001"

  def ctx(actor, id), do: %{command_id: id, actor: actor}
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

  @doc "A hall with alice's open restaurant fully unlocked and stocked."
  def stocked_world(opts \\ []) do
    opts
    |> stocked_world_steps()
    |> Enum.reduce({nil, []}, fn step, {state, _log} = world ->
      {command, actor, id} = step.(state)
      run!(world, command, actor, id)
    end)
  end

  @doc """
  The commands `stocked_world/1` runs, in order. Each step is a function of the
  state reached so far returning `{command, actor, command_id}`, so callers that
  record or replay the setup (the trace properties) issue exactly the same
  commands and IDs.
  """
  def stocked_world_steps(opts \\ []) do
    catalog = Keyword.get(opts, :catalog, SliceCatalog.catalog())
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

    [
      fixed.({:initialize_hall, %{hall_id: "hall-1", catalog: catalog}}, {:system, :admin}, "init"),
      fixed.(
        {:create_restaurant, %{restaurant_id: "r1", stall_id: @stall, name: "Casa Alice", cuisine: "mexican"}},
        owner(),
        "create"
      )
    ] ++ unlocks ++ purchases ++ [fixed.({:open_stall, %{stall_id: @stall}}, owner(), "open")]
  end

  def default_stock do
    %{
      "corn_tortilla" => 40,
      "black_beans_dried" => 1_200,
      "salsa_roja" => 1_500,
      "salsa_verde" => 800,
      "onion" => 600,
      "cilantro" => 200,
      "chicken_thigh" => 2_000,
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

  def stock(world, stock) do
    stock
    |> Enum.sort()
    |> Enum.reduce(world, fn {product, qty}, w ->
      buy(w, product, qty, "buy-#{product}-#{elem(w, 0).now}")
    end)
  end

  def buy(world, product, qty, id), do: run!(world, purchase(product, qty), owner(), id)

  defp purchase(product, qty),
    do: {:purchase_stock, %{restaurant_id: "r1", product: product, qty: qty, max_price_per_kunit: 1_000_000_000}}

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

  def kitchen(world, command, payload, id), do: run!(world, {command, payload}, {:system, :kitchen}, id)

  @doc "Starts every component of a tray, waits for the work, completes it."
  def prepare_tray(world, tray_id) do
    {state, _} = world
    orders = state.trays[tray_id].components

    world = Enum.reduce(orders, world, &kitchen(&2, :start_preparation, %{order_id: &1}, "start-" <> &1))
    {state, _} = world
    ready_at = orders |> Enum.map(&state.orders[&1].ready_not_before) |> Enum.max()
    world = advance_hall(world, ceil_to_tick(ready_at))
    Enum.reduce(orders, world, &kitchen(&2, :complete_preparation, %{order_id: &1}, "complete-" <> &1))
  end

  def prepare_order(world, order_id) do
    world = kitchen(world, :start_preparation, %{order_id: order_id}, "start-" <> order_id)
    {state, _} = world
    world = advance_hall(world, ceil_to_tick(state.orders[order_id].ready_not_before))
    kitchen(world, :complete_preparation, %{order_id: order_id}, "complete-" <> order_id)
  end

  def ceil_to_tick(hall_ms), do: div(hall_ms + Clock.ratio() - 1, Clock.ratio()) * Clock.ratio()

  def tray_id(id), do: "T:" <> id
  def visit_id(id), do: "V:" <> id
end
