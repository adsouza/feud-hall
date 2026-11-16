defmodule FeudHall.Application.MarketGoodsCoverageTest do
  use ExUnit.Case, async: true

  alias FeudHall.Domain.Content.LaunchCatalog

  @goods Path.expand("../../../../app/src/market-goods.json", __DIR__)
  @vendors ~w(greengrocer butcher fishmonger dairy grains spices pantry)

  # Products whose origins say meat, fish or dairy but that are sold elsewhere, by ID.
  @elsewhere %{
    "chicken_broth" => "a broth, sold at the pantry",
    "chicken_broth_chilled" => "a broth, sold at the pantry",
    "pastry_shell" => "bakery dough that contains butter",
    "pastry_shell_frozen" => "bakery dough that contains butter",
    "jamun_mix" => "a dessert batter mix",
    "jamun_mix_basic" => "a dessert batter mix",
    "butter_masala_sauce" => "a sauce that contains cream",
    "butter_masala_sauce_shelf_stable" => "a sauce that contains cream"
  }

  setup_all do
    {:ok, goods: JSON.decode!(File.read!(@goods)), catalog: LaunchCatalog.catalog()}
  end

  test "every catalog product has a vendor and a shape", %{goods: goods, catalog: catalog} do
    missing = Map.keys(catalog.products) -- Map.keys(goods)
    assert missing == []

    for {id, good} <- goods, Map.has_key?(catalog.products, id) do
      assert good["vendor"] in @vendors
      assert good["shape"] in ~w(round leafy root cut fish shellfish sack jar bottle loaf block carton)
      assert good["variant"] in ~w(plain frozen value shelf)
      assert good["colour"] =~ ~r/^#[0-9a-f]{6}$/
    end
  end

  test "an entry for a product the catalog no longer has is a mistake in the file", %{
    goods: goods,
    catalog: catalog
  } do
    assert Map.keys(goods) -- Map.keys(catalog.products) == []
  end

  test "the file is sorted by product ID", %{goods: goods} do
    text = File.read!(@goods)
    ids = Regex.scan(~r/^  "([^"]+)": \{/m, text) |> Enum.map(&Enum.at(&1, 1))
    assert length(ids) == map_size(goods)
    assert ids == Enum.sort(ids)
  end

  test "a substitute sits beside its primary at the same vendor and looks different", %{
    goods: goods,
    catalog: catalog
  } do
    substitutes =
      for {_, recipe} <- catalog.recipes,
          line <- recipe.lines,
          line.substitute != nil,
          uniq: true,
          do: {line.substitute.product, line.product}

    assert length(substitutes) > 100
    assert Enum.uniq_by(substitutes, &elem(&1, 0)) == substitutes

    for {sub, primary} <- substitutes do
      assert goods[sub]["beside"] == primary
      assert goods[sub]["vendor"] == goods[primary]["vendor"]
      assert goods[sub]["shape"] == goods[primary]["shape"]
      assert goods[sub]["variant"] != "plain"
    end

    substitute_ids = MapSet.new(substitutes, &elem(&1, 0))

    for {id, good} <- goods, not MapSet.member?(substitute_ids, id) do
      refute Map.has_key?(good, "beside")
      assert good["variant"] == "plain"
    end
  end

  test "meat, fish and dairy are at their vendors", %{goods: goods, catalog: catalog} do
    expected = fn origins ->
      cond do
        :meat in origins -> "butcher"
        :fish in origins -> "fishmonger"
        :dairy in origins or :egg in origins -> "dairy"
        true -> nil
      end
    end

    checked =
      for {id, product} <- catalog.products,
          vendor = expected.(product.origins),
          not Map.has_key?(@elsewhere, id) do
        assert goods[id]["vendor"] == vendor, "#{id} should be at #{vendor}"
        id
      end

    assert length(checked) > 40

    for {id, reason} <- @elsewhere do
      assert Map.has_key?(catalog.products, id), "#{id} (#{reason}) is no longer a product"
      assert expected.(catalog.products[id].origins) != nil
      assert goods[id]["vendor"] != expected.(catalog.products[id].origins)
    end
  end
end
