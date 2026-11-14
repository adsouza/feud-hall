defmodule FeudHall.Application.ProgressionTest do
  use FeudHall.PostgresCase
  use ExUnitProperties

  alias FeudHall.Application.{CommandWorkflow, Management, Recovery}
  alias FeudHall.Domain.{Clock, Identity}
  alias FeudHall.Domain.Content.{LaunchCatalog, SliceCatalog}
  alias FeudHall.Domain.Hall.Invariants
  alias FeudHall.Infrastructure.{InMemoryEventStore, PostgresEventStore}

  test "all owned locations reject purchases while owners may dine at competitors" do
    alias FeudHall.Application.DinerBrowse
    alias FeudHall.Domain.{Dietary, Offers}

    rt = boot(PostgresEventStore, FeudHall.PostgresCase.fresh_store(), LaunchCatalog.catalog())
    {rt, owner} = register(rt, "owner")
    {rt, rival} = register(rt, "rival")
    actor = {:principal, owner}
    rt = accepted(rt, actor, :reserve_stall, %{stall_id: "s001"})
    rt = accepted(rt, actor, :create_restaurant, location("kitchen", "s001", "levantine"))
    rt = accepted(rt, actor, :lease_location, location("kitchen", "s002", "levantine"))
    rt = accepted(rt, actor, :request_starter_stock, %{restaurant_id: "kitchen", budget: 20_000})
    npc = {:npc, "budget"}
    rt = accepted(rt, npc, :create_restaurant, location("competitor", "s003", "levantine"))
    rt = accepted(rt, npc, :request_starter_stock, %{restaurant_id: "competitor", budget: 20_000})
    rt = advance(rt, max(20 * Clock.minute(), rt.state.stalls["s002"].ready_at))
    rt = accepted(rt, actor, :report_owner_presence, %{present: true})
    rt = accepted(rt, actor, :open_stall, %{stall_id: "s001"})
    rt = accepted(rt, actor, :open_stall, %{stall_id: "s002"})
    rt = accepted(rt, npc, :open_stall, %{stall_id: "s003"})
    rt = accepted(rt, actor, :request_allowance, %{})
    rt = accepted(rt, {:principal, rival}, :request_allowance, %{})
    {:ok, requirement} = Dietary.requirement(rt.state.catalog, "unrestricted")
    diet = %{requirement: requirement, carbs_reserved: 0, carbs_served: 0}

    rt =
      Enum.reduce(~w(s001 s002), rt, fn sid, rt ->
        params = %{stall_id: sid, main: "falafel_wrap", profile_id: "unrestricted"}
        assert {:error, :own_stall_order} = Management.quote(rt, "owner", params)

        assert {:ok, %{checkout_menu: %{mains: mains}}} =
                 Management.view(rt, "owner", %{"stall_id" => sid, "profile_id" => "unrestricted"})

        assert mains == %{}
        assert {:ok, %{options: [], sold_out: []}} = DinerBrowse.compare(rt, "owner", %{"stall_id" => sid})
        # A valid quote obtained before the policy change cannot bypass acceptance.
        assert {:ok, quote} = Offers.quote_tray(rt.state, sid, "falafel_wrap", nil, diet)
        before = rt.state

        assert {:rejected, %{outcome: {:rejected, :own_stall_order}}, rt} =
                 command(rt, actor, :admit_visit, Map.merge(params, %{source: :guest, confirmed: Offers.terms(quote)}))

        assert rt.state == before
        rt
      end)

    assert {:ok, %{options: options}} = DinerBrowse.compare(rt, "owner", %{})
    assert Enum.map(options, & &1.stall_id) == ["s003"]
    assert {:ok, %{options: options}} = DinerBrowse.compare(rt, "rival", %{})
    assert Enum.sort(Enum.map(options, & &1.stall_id)) == ~w(s001 s002 s003)

    rt =
      Enum.reduce([{"owner", owner, "s003"}, {"rival", rival, "s001"}], rt, fn {device, principal, sid}, rt ->
        params = %{stall_id: sid, main: "falafel_wrap", profile_id: "unrestricted"}
        assert {:ok, _} = Management.quote(rt, device, params)
        assert {:ok, quote} = Offers.quote_tray(rt.state, sid, "falafel_wrap", nil, diet)

        accepted(
          rt,
          {:principal, principal},
          :admit_visit,
          Map.merge(params, %{source: :guest, confirmed: Offers.terms(quote)})
        )
      end)

    assert :ok = Invariants.check(rt.state)
    assert {:ok, replay} = CommandWorkflow.open(PostgresEventStore, rt.store)
    assert replay.state == rt.state
  end

  test "catalog expansion keeps existing terms and replays the launch content from PostgreSQL" do
    old = SliceCatalog.catalog()
    rt = boot(PostgresEventStore, FeudHall.PostgresCase.fresh_store(), old)
    npc = {:npc, "budget"}
    rt = accepted(rt, npc, :create_restaurant, location("old-kitchen", "s001", "levantine"))
    rt = accepted(rt, npc, :request_starter_stock, %{restaurant_id: "old-kitchen", budget: 20_000})
    rt = advance(rt, 4 * Clock.minute())
    stock = rt.state.market.stock
    restaurant = rt.state.restaurants["old-kitchen"]
    rt = accepted(rt, {:system, :admin}, :expand_catalog, %{catalog: LaunchCatalog.catalog()})

    assert rt.state.restaurants["old-kitchen"] == restaurant
    assert Map.take(rt.state.catalog.recipes, Map.keys(old.recipes)) == old.recipes
    assert Map.take(rt.state.market.stock, Map.keys(stock)) == stock
    assert map_size(rt.state.catalog.recipes) == 125
    assert {:ok, loaded} = CommandWorkflow.open(PostgresEventStore, rt.store)
    assert loaded.state == rt.state
  end

  test "a newer launch catalog adds Maori without changing pinned businesses, orders or economic pools" do
    alias FeudHall.Domain.{Dietary, Offers}
    alias FeudHall.Infrastructure.Snapshot

    launch = LaunchCatalog.catalog()

    added =
      ~w(puha puha_frozen cabbage cabbage_frozen green_lipped_mussels green_lipped_mussels_frozen golden_syrup golden_syrup_value kawakawa_leaf)

    old_recipes = Map.reject(launch.recipes, fn {_, recipe} -> recipe.cuisine == "maori" end)
    old = %{launch | version: 1, recipes: old_recipes, products: Map.drop(launch.products, added)}

    old =
      put_in(
        old.rules.market.target_stock_per_equivalent,
        Map.drop(old.rules.market.target_stock_per_equivalent, added)
      )

    old = put_in(old.rules.market.replenish_cap, Map.drop(old.rules.market.replenish_cap, added))

    old =
      put_in(
        old.rules.demand.segments,
        Enum.map(old.rules.demand.segments, fn segment ->
          %{segment | main_preference: Map.take(segment.main_preference, Map.keys(old_recipes))}
        end)
      )

    old =
      put_in(old.rules.progression.starter_techniques, Map.delete(old.rules.progression.starter_techniques, "maori"))

    old = put_in(old.profiles["keto_style"].enabled, false)
    old = put_in(old.rules.progression.equipment_cost, 12_345)
    rt = boot(PostgresEventStore, FeudHall.PostgresCase.fresh_store(), old)
    {rt, guest} = register(rt, "guest")
    npc = {:npc, "budget"}
    rt = accepted(rt, npc, :create_restaurant, location("pinned", "s001", "levantine"))
    rt = accepted(rt, npc, :request_starter_stock, %{restaurant_id: "pinned", budget: 20_000})
    rt = accepted(rt, npc, :open_stall, %{stall_id: "s001"})
    rt = accepted(rt, {:system, :visitor_fund}, :grant_allowance, %{principal: guest, amount: 1_200})
    rt = advance(rt, 4 * Clock.minute())
    {:ok, requirement} = Dietary.requirement(rt.state.catalog, "unrestricted")

    {:ok, quote} =
      Offers.quote_tray(rt.state, "s001", "falafel_wrap", nil, %{
        requirement: requirement,
        carbs_reserved: 0,
        carbs_served: 0
      })

    rt =
      accepted(rt, {:principal, guest}, :admit_visit, %{
        source: :guest,
        stall_id: "s001",
        main: "falafel_wrap",
        profile_id: "unrestricted",
        confirmed: Offers.terms(quote)
      })

    before = rt.state
    snapshot_position = rt.position
    snapshot = Snapshot.take(%{hall: rt.state, control: rt.control}, rt.position)
    rt = accepted(rt, {:system, :admin}, :expand_catalog, %{catalog: launch})
    assert rt.state.catalog.version == 3
    assert Map.take(rt.state.catalog.recipes, Map.keys(old_recipes)) == before.catalog.recipes
    assert Map.take(rt.state.catalog.products, Map.keys(old.products)) == before.catalog.products
    assert rt.state.restaurants == before.restaurants
    assert rt.state.orders == before.orders
    assert rt.state.visits == before.visits
    assert rt.state.wallets == before.wallets
    assert rt.state.progression == before.progression
    assert rt.state.visitor_fund == before.visitor_fund
    assert Map.take(rt.state.market.stock, Map.keys(before.market.stock)) == before.market.stock
    assert rt.state.market.stock["puha"] > 0
    assert rt.state.catalog.rules.demand.arrivals_per_equivalent == before.catalog.rules.demand.arrivals_per_equivalent
    assert rt.state.catalog.rules.progression.equipment_cost == 12_345
    refute rt.state.catalog.profiles["keto_style"].enabled
    assert rt.state.catalog.rules.progression.starter_techniques["maori"] == "simmer"
    assert {:rejected, _, same} = command(rt, {:system, :admin}, :expand_catalog, %{catalog: launch})
    assert same.state == rt.state
    assert {:rejected, _, rt} = command(same, {:system, :admin}, :expand_catalog, %{catalog: old})
    rt = advance(rt, quote.earliest_completion + 4 * Clock.minute())
    assert rt.state.stats.served_mains == 1
    assert :ok = Invariants.check(rt.state)
    assert {:ok, loaded} = CommandWorkflow.open(PostgresEventStore, rt.store)
    assert loaded.state == rt.state
    assert {:ok, batches} = PostgresEventStore.read_from(rt.store, snapshot_position)
    assert {:ok, restored} = Snapshot.restore(snapshot, batches)
    assert restored.hall == rt.state
  end

  test "locations share the venture, keep their cuisine, and reopening a dormant venture issues no grant" do
    rt = boot(PostgresEventStore, FeudHall.PostgresCase.fresh_store(), LaunchCatalog.catalog())
    {rt, owner} = register(rt, "owner")
    actor = {:principal, owner}
    rt = accepted(rt, actor, :reserve_stall, %{stall_id: "s001"})
    rt = accepted(rt, actor, :create_restaurant, location("kitchen", "s001", "levantine"))
    rt = accepted(rt, actor, :lease_location, location("kitchen", "s002", "tamil"))
    rt = accepted(rt, actor, :lease_location, location("kitchen", "s003", "japanese"))

    assert {:rejected, %{outcome: {:rejected, :stall_limit}}, _} =
             command(rt, actor, :lease_location, location("kitchen", "s004", "lakota"))

    assert {:ok, view} = Management.view(rt, "owner")
    assert view.profile.restaurant.ledger.capital == "500000"
    assert view.profile.restaurant.ledger.cash == "485000"
    assert view.profile.restaurant.cuisines == ["levantine", "tamil", "japanese"]
    assert Enum.find(view.hall.stalls, &(&1.stall_id == "s002")).menu == %{"idli_with_sambar" => "880"}

    rt =
      Enum.reduce(~w(s001 s002 s003), rt, fn sid, rt ->
        accepted(rt, actor, :surrender_location, %{restaurant_id: "kitchen", stall_id: sid})
      end)

    assert rt.state.stalls == %{}
    assert rt.state.owners[actor] == "kitchen"

    assert {:rejected, %{outcome: {:rejected, :venture_already_active}}, _} =
             command(rt, actor, :create_restaurant, location("new-kitchen", "s001", "tamil"))

    rt = accepted(rt, actor, :join_waitlist, %{tiers: [:quiet]})
    assert rt.state.management.drafts[owner].stall_id == "s001"
    rt = accepted(rt, actor, :lease_location, location("kitchen", "s001", "tamil"))
    assert rt.state.management.drafts == %{}
    assert rt.state.restaurants["kitchen"].ledger.capital == 500_000
    assert :ok = Invariants.check(rt.state)
    assert {:ok, loaded} = CommandWorkflow.open(PostgresEventStore, rt.store)
    assert loaded.state == rt.state
  end

  test "distress freezes bills until bankruptcy and a fresh start retains owner history" do
    catalog =
      LaunchCatalog.catalog()
      |> put_in([:rules, :starter_grant], 5_000)
      |> put_in([:rules, :progression, :distress_ms], 3 * Clock.hour())

    rt = boot(PostgresEventStore, FeudHall.PostgresCase.fresh_store(), catalog)
    {rt, owner} = register(rt, "owner")
    actor = {:principal, owner}
    rt = accepted(rt, actor, :reserve_stall, %{stall_id: "s001"})
    rt = accepted(rt, actor, :create_restaurant, location("first", "s001", "levantine"))
    rt = accepted(rt, actor, :request_allowance, %{})
    rt = advance(rt, Clock.hour())
    deadline = 4 * Clock.hour()
    assert rt.state.progression.distress["first"] == deadline
    arrears = rt.state.management.leases["s001"].arrears
    assert arrears > 0
    accrued = Map.take(rt.state.management.leases["s001"], [:rent_accrued, :wages_accrued])

    assert {:rejected, %{outcome: {:rejected, :business_distressed}}, _} =
             command(rt, actor, :open_stall, %{stall_id: "s001"})

    rt = advance(rt, deadline - Clock.ratio())
    assert rt.state.management.leases["s001"].arrears == arrears
    assert Map.take(rt.state.management.leases["s001"], [:rent_accrued, :wages_accrued]) == accrued
    rt = advance(rt, deadline)
    assert rt.state.owners[actor] == nil
    assert rt.state.stalls == %{}
    assert rt.state.progression.history["first"].unpaid == arrears
    assert PostgresEventStore.projection(rt.store, :balances) == []
    assert PostgresEventStore.projection(rt.store, :stock) == []

    rt = accepted(rt, actor, :reserve_stall, %{stall_id: "s001"})
    rt = accepted(rt, actor, :create_restaurant, location("second", "s001", "tamil"))
    assert rt.state.owners[actor] == "second"
    assert rt.state.restaurants["second"].ledger.capital == 5_000
    assert {:ok, %{profile: %{balance: "1200", ventures: [%{id: "first"}]}}} = Management.view(rt, "owner")
    assert {:ok, %{hall: %{failed_ventures: [public]}, profile: nil}} = Management.view(rt, nil)
    refute Map.has_key?(public, :final_ledger)
    assert {:ok, loaded} = CommandWorkflow.open(PostgresEventStore, rt.store)
    assert loaded.state == rt.state
  end

  test "a distressed owner can surrender, salvage inventory, and settle the same debt from dormancy" do
    catalog = put_in(LaunchCatalog.catalog().rules.starter_grant, 5_100)
    rt = boot(PostgresEventStore, FeudHall.PostgresCase.fresh_store(), catalog)
    {rt, owner} = register(rt, "owner")
    actor = {:principal, owner}
    rt = accepted(rt, actor, :reserve_stall, %{stall_id: "s001"})
    rt = accepted(rt, actor, :create_restaurant, location("kitchen", "s001", "tamil"))

    rt =
      accepted(rt, actor, :submit_purchase_request, %{
        restaurant_id: "kitchen",
        product: "rice_long",
        qty: 350,
        max_price_per_kunit: 280
      })

    rt = advance(rt, Clock.hour())
    debt = rt.state.management.leases["s001"].arrears
    assert debt > 0
    [batch] = Map.keys(rt.state.restaurants["kitchen"].batches)

    rt = accepted(rt, actor, :surrender_location, %{restaurant_id: "kitchen", stall_id: "s001"})
    assert rt.state.stalls == %{}
    assert rt.state.progression.ventures["kitchen"].released_debt == debt

    assert {:rejected, %{outcome: {:rejected, :arrears_unpayable}}, _} =
             command(rt, actor, :pay_arrears, %{restaurant_id: "kitchen"})

    rt = accepted(rt, actor, :salvage_stock, %{restaurant_id: "kitchen", batch_id: batch})

    assert {:rejected, %{outcome: {:rejected, :salvage_unavailable}}, _} =
             command(rt, actor, :salvage_stock, %{restaurant_id: "kitchen", batch_id: batch})

    rt = accepted(rt, actor, :pay_arrears, %{restaurant_id: "kitchen"})
    assert rt.state.progression.distress == %{}
    assert rt.state.owners[actor] == "kitchen"
    assert rt.state.restaurants["kitchen"].ledger.capital == 5_100
    assert rt.state.restaurants["kitchen"].batches == %{}
    assert {:ok, loaded} = CommandWorkflow.open(PostgresEventStore, rt.store)
    assert loaded.state == rt.state
  end

  test "award windows count finalized simulated mains once, then replace expired active awards" do
    alias FeudHall.Domain.Hall.{Evolver, Recognition}

    rt = boot(InMemoryEventStore, InMemoryEventStore.new(), LaunchCatalog.catalog())
    rt = accepted(rt, {:npc, "budget"}, :create_restaurant, location("kitchen", "s001", "tamil"))
    finalized = %{competitive: true, score: 9_000, components: [%{kind: :main, outcome: :served}]}
    visit = %{restaurant: "kitchen", stall: "s001", source: :simulated}
    state = Enum.reduce(1..49, rt.state, fn _, state -> Recognition.observe(state, visit, finalized) end)
    state = Recognition.observe(state, %{visit | source: :guest}, finalized)
    state = Recognition.observe(state, visit, %{finalized | components: [%{kind: :main, outcome: :failed}]})
    assert %{awarded: []} = Recognition.review(state)
    state = Recognition.observe(state, visit, finalized)
    assert %{awarded: [_, _]} = event = Recognition.review(state)
    state = Evolver.evolve(state, event)
    assert Recognition.multiplier(state, "kitchen", "tamil") <= 1_200
    assert Recognition.multiplier(state, "kitchen", "tamil") >= 1_150
    state = Evolver.evolve(state, Recognition.review(state))
    assert Recognition.active_awards(state, "kitchen") == []
    assert length(Recognition.awards(state, "kitchen")) == 2
  end

  test "equipment and menu overrides belong to one physical location and stored equipment is reusable" do
    rt = boot(PostgresEventStore, FeudHall.PostgresCase.fresh_store(), LaunchCatalog.catalog())
    {rt, owner} = register(rt, "owner")
    actor = {:principal, owner}
    rt = accepted(rt, actor, :reserve_stall, %{stall_id: "s001"})
    rt = accepted(rt, actor, :create_restaurant, location("kitchen", "s001", "tamil"))
    rt = accepted(rt, actor, :lease_location, location("kitchen", "s002", "tamil"))
    quote = %{restaurant_id: "kitchen", stall_id: "s001", recipe_id: "masala_dosa"}

    assert {:ok, %{profile: %{restaurant: %{stalls: [first, second]}}}} = Management.view(rt, "owner")
    assert first.unlock_offers["masala_dosa"].equipment == "12000"
    assert second.unlock_offers["masala_dosa"].known == false

    assert {:rejected, %{outcome: {:rejected, :stale_terms}}, _} =
             command(rt, actor, :unlock_recipe, Map.put(quote, :max_cost, 37_999))

    rt = accepted(rt, actor, :unlock_recipe, Map.put(quote, :max_cost, 38_000))
    rt = accepted(rt, actor, :set_menu_price, Map.put(quote, :price, 1_200))
    assert {:ok, %{hall: %{stalls: [first, second]}}} = Management.view(rt, nil)
    assert first.menu["masala_dosa"] == "1200"
    refute Map.has_key?(second.menu, "masala_dosa")

    rt = accepted(rt, actor, :surrender_location, %{restaurant_id: "kitchen", stall_id: "s002"})
    rt = accepted(rt, actor, :surrender_location, %{restaurant_id: "kitchen", stall_id: "s001"})
    rt = accepted(rt, actor, :lease_location, location("kitchen", "s003", "tamil"))
    cash = rt.state.restaurants["kitchen"].ledger.cash
    rt = accepted(rt, actor, :unlock_recipe, %{quote | stall_id: "s003"} |> Map.put(:max_cost, 0))
    assert rt.state.restaurants["kitchen"].ledger.cash == cash
    assert rt.state.stalls["s003"].equipment == %{"griddle" => 12_000}
    rt = accepted(rt, actor, :refit_location, location("kitchen", "s003", "japanese"))
    assert rt.state.stalls["s003"].cuisine == "japanese"
    assert rt.state.progression.ventures["kitchen"].stored_equipment["griddle"] == [12_000]

    assert {:rejected, %{outcome: {:rejected, :location_refitting}}, _} =
             command(rt, actor, :open_stall, %{stall_id: "s003"})

    ready = rt.state.stalls["s003"].ready_at
    rt = advance(rt, ready)
    rt = accepted(rt, actor, :report_owner_presence, %{present: true})
    rt = accepted(rt, actor, :open_stall, %{stall_id: "s003"})
    assert rt.state.stalls["s003"].mode == :open
    assert :ok = Invariants.check(rt.state)
    assert {:ok, loaded} = CommandWorkflow.open(PostgresEventStore, rt.store)
    assert loaded.state == rt.state
  end

  test "population latches only with 13 leased owners, recovers fresh presence, and restores retained NPC capital" do
    alias FeudHall.Domain.{Demand, Hall}
    alias FeudHall.Domain.Hall.Population

    rt = boot(InMemoryEventStore, InMemoryEventStore.new(), LaunchCatalog.catalog())

    {rt, owners} =
      Enum.reduce(1..13, {rt, []}, fn n, {rt, owners} ->
        {rt, id} = register(rt, "owner-#{n}")
        actor = {:principal, id}
        sid = "s" <> String.pad_leading(Integer.to_string(n), 3, "0")
        rt = accepted(rt, actor, :reserve_stall, %{stall_id: sid})
        rt = accepted(rt, actor, :create_restaurant, location("kitchen-#{n}", sid, "japanese"))
        {rt, [actor | owners]}
      end)

    npcs = [
      {"budget", "s020", "levantine"},
      {"mainstream", "s041", "tamil"},
      {"premium", "s140", "mughlai_punjabi"}
    ]

    rt =
      Enum.reduce(npcs, rt, fn {op, sid, cuisine}, rt ->
        actor = {:npc, op}

        rt
        |> accepted(actor, :create_restaurant, location("npc-" <> op, sid, cuisine))
        |> accepted(actor, :request_starter_stock, %{restaurant_id: "npc-" <> op, budget: 20_000})
        |> accepted(actor, :open_stall, %{stall_id: sid})
      end)

    human = List.last(owners)
    rt = accepted(rt, human, :request_starter_stock, %{restaurant_id: "kitchen-1", budget: 20_000})
    rt = advance(rt, 4 * Clock.minute())
    rt = Enum.reduce(owners, rt, &accepted(&2, &1, :report_owner_presence, %{present: true}))
    rt = accepted(rt, human, :open_stall, %{stall_id: "s001"})

    state = rt.state
    operating = Demand.operating(state)
    assert length(operating) == 4
    window = Clock.service_duration(300_000)
    {:principal, absent} = hd(owners)
    twelve = update_in(state.management.presence, &Map.delete(&1, absent))
    refute Population.observe(twelve, window, operating).progression.population.eligible
    refute Population.observe(state, window - 1, operating).progression.population.eligible
    ready = Population.observe(state, window, operating)
    assert ready.progression.population.eligible

    assert Population.observe(%{ready | access: :cleaning}, window, []).progression.population ==
             ready.progression.population

    closes = Population.evaluate(ready)
    assert Enum.any?(closes, &match?(%{type: :npc_retirement_scheduled, restaurant_id: "npc-budget"}, &1))
    closing = Hall.replay(closes, ready)
    recovered = Hall.replay([%{type: :management_resumed}], closing)
    refute recovered.progression.population.eligible
    assert Population.closing?(recovered, "npc-budget")
    dormant = Hall.replay(Population.finish_retirement(recovered, "npc-budget"), recovered)
    assert length(Demand.operating(dormant)) == 2
    assert dormant.owners[{:npc, "budget"}] == "npc-budget"
    assert dormant.restaurants["npc-budget"].ledger.capital == 500_000
    refute Map.has_key?(dormant.stalls, "s020")

    short = Population.observe(dormant, Clock.service_duration(600_000), Demand.operating(dormant))
    restoration = Population.evaluate(short)
    refute Enum.any?(restoration, &(&1.type == :starter_grant_issued))
    restored = Hall.replay(restoration, short)
    assert length(FeudHall.Domain.Hall.Progression.stalls(restored, "npc-budget")) == 1
    assert restored.restaurants["npc-budget"].ledger.capital == 500_000
    assert :ok = Invariants.check(restored)
  end

  test "completed receipts page consistently by committed admission and are private to the canonical guest" do
    alias FeudHall.Application.DiningHistory
    alias FeudHall.Domain.{Dietary, Offers}

    rt = boot(PostgresEventStore, FeudHall.PostgresCase.fresh_store(), SliceCatalog.catalog())
    {rt, owner} = register(rt, "guest")
    {rt, _} = register(rt, "stranger")
    npc = {:npc, "budget"}
    rt = accepted(rt, npc, :create_restaurant, location("kitchen", "s001", "levantine"))
    rt = accepted(rt, npc, :request_starter_stock, %{restaurant_id: "kitchen", budget: 20_000})
    rt = accepted(rt, npc, :open_stall, %{stall_id: "s001"})
    rt = accepted(rt, {:principal, owner}, :request_allowance, %{})
    rt = advance(rt, 4 * Clock.minute())
    {:ok, requirement} = Dietary.requirement(rt.state.catalog, "unrestricted")
    diet = %{requirement: requirement, carbs_served: 0, carbs_reserved: 0}

    admit = fn current, id ->
      assert {:ok, quote} = Offers.quote_tray(current.state, "s001", "falafel_wrap", nil, diet)

      assert {:accepted, _, next} =
               CommandWorkflow.execute(current, %{
                 actor: {:principal, owner},
                 command_id: id,
                 command:
                   {:admit_visit,
                    %{
                      source: :guest,
                      stall_id: "s001",
                      main: "falafel_wrap",
                      profile_id: "unrestricted",
                      confirmed: Offers.terms(quote)
                    }}
               })

      next
    end

    rt =
      Enum.reduce(1..22, rt, fn index, current ->
        id = "dining-#{index}"
        current = admit.(current, id)
        accepted(current, {:principal, owner}, :cancel_tray, %{tray_id: "T:" <> id})
      end)

    rt = admit.(rt, "still-active")
    assert {:ok, %{before: cursor, receipts: first}} = DiningHistory.page(rt, "guest", nil)
    assert length(first) == 20
    assert hd(first).visit_id == "V:dining-22"
    assert Enum.all?(first, &match?(%{total: "0", courses: [%{outcome: :guest_cancelled}]}, &1))
    assert {:ok, %{before: nil, receipts: [second, oldest]}} = DiningHistory.page(rt, "guest", cursor)
    assert [second.visit_id, oldest.visit_id] == ["V:dining-2", "V:dining-1"]
    assert {:ok, %{receipts: []}} = DiningHistory.page(rt, "stranger", cursor)
    assert {:error, :unauthenticated} = DiningHistory.page(rt, nil, cursor)
    assert {:error, :invalid_history_cursor} = DiningHistory.page(rt, "guest", "broken")
    assert {:ok, recovered} = CommandWorkflow.open(PostgresEventStore, rt.store)
    assert {:ok, %{receipts: ^first}} = DiningHistory.page(recovered, "guest", nil)
  end

  test "one durable receipt joins a served tray and separately accepted dessert" do
    alias FeudHall.Application.DiningHistory
    alias FeudHall.Domain.{Dietary, Offers}

    rt = boot(PostgresEventStore, FeudHall.PostgresCase.fresh_store(), LaunchCatalog.catalog())
    {rt, guest} = register(rt, "guest")
    npc = {:npc, "budget"}
    rt = accepted(rt, npc, :create_restaurant, location("kitchen", "s001", "levantine"))
    main = "falafel_wrap"
    drink = "mint_lemonade"
    dessert = "knafeh"
    recipes = Map.take(rt.state.catalog.recipes, [main, drink, dessert])

    rt =
      Enum.reduce([drink, dessert], rt, fn id, current ->
        current
        |> accepted(npc, :unlock_recipe, %{restaurant_id: "kitchen", recipe_id: id})
        |> accepted(npc, :set_menu_price, %{restaurant_id: "kitchen", recipe_id: id, price: recipes[id].suggested_price})
      end)

    quantities =
      recipes
      |> Map.values()
      |> Enum.flat_map(& &1.lines)
      |> Enum.reduce(%{}, fn line, quantities ->
        Map.update(quantities, line.product, line.qty, &(&1 + line.qty))
      end)

    rt =
      Enum.reduce(quantities, rt, fn {product, qty}, current ->
        accepted(current, npc, :submit_purchase_request, %{
          restaurant_id: "kitchen",
          product: product,
          qty: qty,
          max_price_per_kunit: 1_000_000
        })
      end)
      |> accepted(npc, :open_stall, %{stall_id: "s001"})
      |> accepted({:system, :visitor_fund}, :grant_allowance, %{principal: guest, amount: 2_400})
      |> advance(4 * Clock.minute())

    {:ok, requirement} = Dietary.requirement(rt.state.catalog, "unrestricted")
    diet = %{requirement: requirement, carbs_reserved: 0, carbs_served: 0}
    assert {:ok, quote} = Offers.quote_tray(rt.state, "s001", main, drink, diet)

    rt =
      accepted(rt, {:principal, guest}, :admit_visit, %{
        source: :guest,
        stall_id: "s001",
        main: main,
        drink: drink,
        profile_id: "unrestricted",
        confirmed: Offers.terms(quote)
      })

    rt = advance(rt, quote.earliest_completion)
    visit = rt.state.visits[rt.state.active_visits[guest]]
    assert visit.dessert == :offered
    assert {:ok, %{receipts: []}} = DiningHistory.page(rt, "guest", nil)
    assert {:ok, quote} = Offers.quote_dessert(rt.state, visit)

    # Model a pre-policy self-order: accepted main/drink terms remain untouched,
    # but neither the quote endpoint nor the domain permits a new dessert purchase.
    legacy =
      rt
      |> put_in([Access.key(:state), :restaurants, "kitchen", :owner_kind], :principal)
      |> put_in([Access.key(:state), :restaurants, "kitchen", :owner], guest)

    assert legacy.state.orders == rt.state.orders
    assert {:error, :own_stall_order} = Management.quote(legacy, "guest", %{visit_id: visit.id})

    assert {:error, :own_stall_order} =
             FeudHall.Domain.Hall.decide(
               legacy.state,
               {:accept_dessert, %{visit_id: visit.id, confirmed: Offers.terms(quote)}},
               %{actor: {:principal, guest}, command_id: "legacy-dessert"}
             )

    rt = accepted(rt, {:principal, guest}, :accept_dessert, %{visit_id: visit.id, confirmed: Offers.terms(quote)})
    rt = advance(rt, quote.earliest_completion + 4 * Clock.minute())

    assert {:ok, %{receipts: [receipt]}} = DiningHistory.page(rt, "guest", nil)
    assert Enum.map(receipt.courses, & &1.recipe_id) == [main, drink, dessert]
    assert Enum.all?(receipt.courses, &(&1.outcome == :served))
    assert receipt.total == "1800"
    assert receipt.at == quote.earliest_completion
    assert {:ok, %{profile: %{balance: "600"}}} = Management.view(rt, "guest")
  end

  property "clock partitions preserve distress and exact bankruptcy across cleaning" do
    catalog =
      LaunchCatalog.catalog()
      |> put_in([:rules, :starter_grant], 5_000)
      |> put_in([:rules, :progression, :distress_ms], 3 * Clock.hour())

    rt = boot(InMemoryEventStore, InMemoryEventStore.new(), catalog)
    {rt, owner} = register(rt, "owner")
    actor = {:principal, owner}
    rt = accepted(rt, actor, :reserve_stall, %{stall_id: "s001"})
    rt = accepted(rt, actor, :create_restaurant, location("kitchen", "s001", "tamil"))

    deadline = 4 * Clock.hour()
    whole = advance(rt, deadline)
    assert whole.state.progression.history["kitchen"].ended_at == deadline

    check all(
            cuts <- list_of(integer(1..(Clock.service_ms(deadline) - 1)), min_length: 1, max_length: 8),
            max_runs: 16
          ) do
      partitioned =
        cuts
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.map(&Clock.service_duration/1)
        |> Kernel.++([deadline])
        |> Enum.reduce(rt, fn at, current -> advance(current, at) end)

      assert partitioned.state == whole.state
      assert :ok = Invariants.check(partitioned.state)
    end
  end

  defp boot(adapter, store, catalog) do
    {:ok, rt, _} = Recovery.recover(adapter, store, "progression", scope: "hall:test")

    accepted(rt, {:system, :admin}, :initialize_hall, %{
      hall_id: "h1",
      catalog: FeudHall.Fixtures.quiet_catalog(catalog),
      managed: true
    })
  end

  defp register(rt, device) do
    assert {:ok, envelope} =
             Management.envelope(rt.control, device, %{
               command_id: "register-" <> device,
               command: {:bootstrap_guest, %{name: device}}
             })

    assert {:accepted, _, rt} = CommandWorkflow.execute(rt, envelope)
    principal = Identity.principal_for_device(Identity.get(rt.control), device)
    rt = accepted(rt, {:system, :admin}, :seed_owner, %{principal: principal, reviewer?: false})
    {rt, principal}
  end

  defp location(id, sid, cuisine), do: %{restaurant_id: id, stall_id: sid, name: id, cuisine: cuisine}
  defp advance(rt, at), do: accepted(rt, {:system, :scheduler}, :advance_clock, %{to_service_ms: Clock.service_ms(at)})

  defp accepted(rt, actor, kind, payload) do
    assert {:accepted, _, rt} = command(rt, actor, kind, payload)
    rt
  end

  defp command(rt, actor, kind, payload) do
    id = "m4-#{System.unique_integer([:positive])}"
    CommandWorkflow.execute(rt, %{command_id: id, actor: actor, command: {kind, payload}})
  end
end
