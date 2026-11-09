defmodule FeudHall.Domain.DietaryAndContentTest do
  use ExUnit.Case, async: true

  import FeudHall.Fixtures

  alias FeudHall.Domain.{Content, Dietary, Hall}
  alias FeudHall.Domain.Content.SliceCatalog
  alias FeudHall.Oracle

  describe "hard dietary compatibility" do
    test "incompatible mains are rejected regardless of price; compatible ones are accepted" do
      w = stocked_world()
      # Even at a price of one cent, a vegan cannot buy cheese.
      w =
        run!(
          w,
          {:set_menu_price, %{restaurant_id: "r1", recipe_id: "vegetable_quesadilla", price: 1}},
          owner(),
          "cheap"
        )

      {state, _} = w

      assert {:error, {:excluded_ingredient, "queso_oaxaca", :dairy}} =
               admit(state, "v1", "vegetable_quesadilla", nil, "vegan")

      assert {:error, {:excluded_ingredient, "chicken_thigh", :meat}} =
               admit(state, "v2", "chicken_tacos", nil, "vegetarian")

      assert {:ok, _} = admit(state, "v3", "bean_tacos", "horchata", "vegan")
      # Unrestricted diners may buy restricted-diet food.
      assert {:ok, _} = admit(state, "v4", "bean_tacos", nil, "unrestricted")
    end

    test "missing metadata is never compatible with a requirement" do
      # Vegan is disabled here: with cilantro's metadata missing, validation
      # (correctly) finds no viable vegan main.
      catalog = SliceCatalog.catalog(enable: ~w(unrestricted vegetarian carb_conscious))
      catalog = put_in(catalog, [:products, "cilantro", :origins], nil)
      catalog = put_in(catalog, [:recipes, "bean_tacos", :claims], [])
      w = stocked_world(catalog: catalog)
      {state, _} = w
      assert {:error, {:missing_metadata, "cilantro"}} = admit(state, "v1", "bean_tacos", nil, "vegetarian")
      assert {:ok, _} = admit(state, "v2", "bean_tacos", nil, "unrestricted")
    end

    test "a tray must fit the carbohydrate ceiling as a whole; carbs round up once per portion" do
      w = stocked_world()
      {state, _} = w
      # Chicken tacos: 2 x 12 g + 40 g x 60 mg/g + 20 g x 90 mg/g = 28,200 mg.
      assert {:ok, events} = admit(state, "c1", "chicken_tacos", nil, "carb_conscious")
      [%{components: [main]}] = Enum.filter(events, &(&1.type == :tray_accepted))
      assert main.carbs_mg == 28_200

      # Horchata adds 44,800 mg: 73,000 > 45,000, so the whole tray is refused.
      assert {:error, :carbohydrate_limit} = admit(state, "c2", "chicken_tacos", "horchata", "carb_conscious")
    end

    test "dessert is not offered when it would exceed the remaining carbohydrate allowance" do
      w = stocked_world() |> simulated_visit("c1", "chicken_tacos", nil, "carb_conscious")
      w = prepare_tray(w, tray_id("visit-c1")) |> kitchen(:serve_tray, %{tray_id: tray_id("visit-c1")}, "serve")
      {state, events} = w
      visit = state.visits[visit_id("visit-c1")]
      assert visit.carbs_served == 28_200
      assert visit.status == :finalized
      assert visit.outcome.components |> Enum.map(& &1.kind) == [:main]
      Oracle.assert_settled!(state, events)
    end

    test "the dessert shares the visit's ceiling with the already served tray" do
      # 90 g ceiling: dessert alone (67,400 mg) fits, main + dessert does not.
      catalog = put_in(SliceCatalog.catalog(), [:profiles, "carb_conscious", :carb_ceiling_mg], 90_000)
      w = stocked_world(catalog: catalog) |> simulated_visit("c1", "chicken_tacos", nil, "carb_conscious")
      w = prepare_tray(w, tray_id("visit-c1")) |> kitchen(:serve_tray, %{tray_id: tray_id("visit-c1")}, "serve")
      {state, _} = w
      assert state.visits[visit_id("visit-c1")].status == :finalized

      # The same diner profile with an unrestricted first course gets the offer.
      w = stocked_world(catalog: catalog) |> simulated_visit("u1", "chicken_tacos", nil, "unrestricted")
      w = prepare_tray(w, tray_id("visit-u1")) |> kitchen(:serve_tray, %{tray_id: tray_id("visit-u1")}, "serve")
      {state, _} = w
      assert state.visits[visit_id("visit-u1")].dessert == :offered
    end

    test "portion carbohydrate rounds up exactly once after the whole bill" do
      catalog = SliceCatalog.catalog()
      lines = [%{product: "cinnamon", qty: 1}, %{product: "cinnamon", qty: 1}]
      # 2 g x 800,000 mg/kunit = 1,600 mg exactly (no per-line rounding).
      assert {:ok, 1_600} = Dietary.portion_carbs(catalog, lines)
      odd = put_in(catalog, [:products, "cinnamon", :carb_mg_per_kunit], 1)
      assert {:ok, 1} = Dietary.portion_carbs(odd, lines)
    end
  end

  describe "content validation" do
    test "the slice catalog is valid and hashes deterministically" do
      assert :ok = Content.validate(SliceCatalog.catalog())
      assert Content.hash(SliceCatalog.catalog()) == Content.hash(SliceCatalog.catalog())
    end

    test "a profile without any viable main cannot be enabled" do
      catalog = SliceCatalog.catalog(enable: ~w(unrestricted vegetarian vegan carb_conscious keto_style))
      assert {:error, problems} = Content.validate(catalog)
      assert {:profile, "keto_style", :no_viable_main} in problems
    end

    test "invalid conversions, recursive or claim-breaking substitutes, and incomplete cuisines are rejected" do
      base = SliceCatalog.catalog()

      bad_conv = put_in(base, [:recipes, "bean_tacos", :lines], bean_lines(base, &%{&1 | den: 0}))
      assert {:error, problems} = Content.validate(bad_conv)
      assert {:recipe_line, "bean_tacos", "tortilla", :bad_conversion} in problems

      meaty_sub =
        put_in(base, [:recipes, "bean_tacos", :lines], bean_lines(base, &%{&1 | product: "chicken_thigh"}))

      assert {:error, problems} = Content.validate(meaty_sub)
      assert {:recipe_line, "bean_tacos", "tortilla", :substitute_breaks_claim} in problems

      missing = update_in(base, [:recipes], &Map.delete(&1, "horchata"))
      assert {:error, problems} = Content.validate(missing)
      assert {:cuisine, "mexican", :needs_one_drink} in problems

      stricter = put_in(base, [:profiles, "keto_style", :carb_ceiling_mg], 50_000)
      assert {:error, problems} = Content.validate(stricter)
      assert {:profile, "keto_style", :not_stricter} in problems
    end

    test "removing metadata from the only vegan main makes enabling vegan invalid" do
      catalog = put_in(SliceCatalog.catalog(), [:products, "cilantro", :origins], nil)
      catalog = put_in(catalog, [:recipes, "bean_tacos", :claims], [])
      assert {:error, [{:profile, "vegan", :no_viable_main}]} = Content.validate(catalog)
    end

    test "a hall refuses invalid content at genesis" do
      bad = put_in(SliceCatalog.catalog(), [:products, "sugar", :base_price_per_kunit], 0)

      assert {:error, {:invalid_content, [{:product, "sugar", :bad_price}]}} =
               Hall.decide(nil, {:initialize_hall, %{hall_id: "h", catalog: bad}}, ctx({:system, :admin}, "i"))
    end
  end

  defp bean_lines(catalog, sub_fun) do
    Enum.map(catalog.recipes["bean_tacos"].lines, fn
      %{line_id: "tortilla", substitute: s} = l -> %{l | substitute: sub_fun.(s)}
      l -> l
    end)
  end

  defp admit(state, id, main, drink, profile) do
    Hall.decide(
      state,
      {:admit_visit,
       %{
         source: :simulated,
         diner_id: id,
         budget: 10_000,
         stall_id: "s1",
         main: main,
         drink: drink,
         profile_id: profile
       }},
      ctx({:system, :demand}, id)
    )
  end
end
