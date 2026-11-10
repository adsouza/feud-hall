defmodule FeudHall.Infrastructure.EventCodec do
  @moduledoc """
  Portable JSON codec for domain events (schema version 1).

  Integers stay exact JSON integers on the server side; Elixir's JSON decoder
  preserves arbitrary precision. Atoms are encoded as `{"$a": name}` and
  decoded only through an explicit allowlist, so stored or client-supplied
  strings never mint atoms. Maps whose keys are not atoms (catalog products,
  recipes, and profiles keyed by stable string IDs) are encoded as ordered
  `{"$map": [[key, value], ...]}` pairs. An unknown schema version or atom is
  an error that must block replay rather than be skipped.
  """

  @schema 1

  @atoms ~w(
    hall_initialized clock_advanced hall_cleaning_started hall_cleaning_ended restaurant_created
    starter_grant_issued stall_opened stall_closed recipe_unlocked menu_price_set menu_item_removed
    substitution_policy_set stock_purchased stock_spoiled allowance_granted visit_admitted tray_accepted
    reservation_replaced preparation_started preparation_completed tray_served tray_cancelled
    dessert_offered dessert_declined dessert_accepted dessert_served dessert_cancelled visit_finalized
    guest simulated main drink dessert primary_only prefer_primary prefer_substitute g ml each
    plant mineral meat fish dairy egg honey gelatin animal_rennet animal_fat_stock vegetarian vegan
    cleaning guest_cancelled deadline_missed ingredient_expired ready_food_expired completed main_failed
    dessert_cancelled dessert_failed dessert_offer_expired dessert_offer_withdrawn served cleaning_exempt failed
    type hall_id content_hash catalog visitor_fund to day at restaurant_id owner name cuisine
    starter_recipe stall_id amount recipe_id cost price line_id policy batch_id product product_version
    qty expires_at principal slice_id visit_id source requirement budget tray_id deadline components
    order_id kind recipe_version lines penalty quality reservations funding carbs_mg substituted released
    claimed consumed ready_not_before reason waste_cost score competitive weight outcome order profile_id
    excludes carb_ceiling_mg id version rules products recipes profiles quality_base
    substitution_penalty_cap course_weights dessert_window_service_ms handover_ms service_window_ms
    starter_grant storage_capacity max_allowance_grant unit origins carb_mg_per_kunit
    base_price_per_kunit shelf_life_ms storage_per_kunit starter unlock_cost claims suggested_price
    prep_ms finish_ms holding_ms substitute num den enabled stricter_than
    availability_started availability_resumed hall_resumed epoch_id recovery_id hall_ms catalog_ref
    owner_kind npc
    seed exposure_permille kitchen market demand layout npc_profiles prep_stations finish_stations
    queue_limit clear_every_hall_ms price_floor_permille price_ceiling_permille
    target_stock_per_equivalent replenish_cap arrivals_per_equivalent equivalent_floor_millis
    operating_hours_ms hourly_weights segments profile_mix variety_weight variety_cap
    patience_service_ms drink_attach_permille dessert_appetite_permille price_weight quality_weight
    wait_weight leave_weight main_preference slot_id tier quiet standard busy prime price_permille
    restock_days preferred_tier stock requests by_key batch next_clear_at rng
    stage_started stage_completed handover_started stage prep finish done_at item tray estimated_completion
    purchase_requested purchase_request_cancelled market_cleared request_id max_price_per_kunit replaces
    prices fills unfilled price_above_limit insufficient_cash insufficient_storage stock_exhausted
    day_closed operating equivalents_millis scale_millis replenishment summary arrivals admitted left
    trays_served menu_prices_median
    diner_arrived arrival_id segment patience_hall_ms drink? dessert_appetite? hour_quotas_millis
    no_compatible_main nothing_affordable wait_too_long chose_to_leave admission_failed
    npc_planned operator slot next_slot_at outcomes result accepted rejected action other
    open_stall close_stall unlock_recipe set_menu_price remove_menu_item set_substitution_policy
    submit_purchase_request cancel_purchase_request
    unknown_stall unknown_restaurant forbidden unknown_recipe wrong_cuisine already_unlocked recipe_locked
    invalid_price not_on_menu unknown_line invalid_policy no_approved_substitute unknown_product
    invalid_quantity invalid_price_limit no_pending_request unauthorized_or_malformed malformed_command
    action_not_allowed malformed_action unrecognised_reason
  )a

  @by_name Map.new(@atoms, &{Atom.to_string(&1), &1})
  @allowed MapSet.new(@atoms)

  @doc "The schema version written into every encoded event."
  def schema, do: @schema

  @doc "Encodes one event to a JSON binary."
  def encode!(event), do: JSON.encode!(%{"v" => @schema, "e" => to_json(event)})

  @doc "Decodes one event, failing on unknown schema versions or atoms."
  def decode(binary) do
    with {:ok, %{"v" => @schema, "e" => data}} <- JSON.decode(binary) do
      try do
        {:ok, from_json(data)}
      catch
        {:unknown_atom, name} -> {:error, {:unknown_atom, name}}
      end
    else
      {:ok, %{"v" => v}} -> {:error, {:unsupported_schema, v}}
      {:ok, _} -> {:error, :malformed_event}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp to_json(value) when is_boolean(value) or is_nil(value), do: value

  defp to_json(value) when is_atom(value) do
    if MapSet.member?(@allowed, value),
      do: %{"$a" => Atom.to_string(value)},
      else: raise(ArgumentError, "atom #{inspect(value)} is not in the event codec allowlist")
  end

  defp to_json(value) when is_integer(value) or is_binary(value), do: value
  defp to_json(value) when is_list(value), do: Enum.map(value, &to_json/1)

  defp to_json(value) when is_map(value) do
    if Enum.all?(Map.keys(value), &is_atom/1) do
      Map.new(value, fn {k, v} -> {atom_key!(k), to_json(v)} end)
    else
      %{"$map" => value |> Enum.sort() |> Enum.map(fn {k, v} -> [to_json(k), to_json(v)] end)}
    end
  end

  defp atom_key!(key) do
    if MapSet.member?(@allowed, key),
      do: Atom.to_string(key),
      else: raise(ArgumentError, "key #{inspect(key)} is not in the event codec allowlist")
  end

  defp from_json(%{"$a" => name}), do: atom!(name)
  defp from_json(%{"$map" => pairs}), do: Map.new(pairs, fn [k, v] -> {from_json(k), from_json(v)} end)
  defp from_json(map) when is_map(map), do: Map.new(map, fn {k, v} -> {atom!(k), from_json(v)} end)
  defp from_json(list) when is_list(list), do: Enum.map(list, &from_json/1)
  defp from_json(value), do: value

  defp atom!(name) do
    case Map.fetch(@by_name, name) do
      {:ok, atom} -> atom
      :error -> throw({:unknown_atom, name})
    end
  end
end
