defmodule FeudHall.Web.Protocol do
  @moduledoc "Explicit mapping from browser JSON to application command envelopes."
  alias FeudHall.Application.Management
  alias FeudHall.Domain.Money
  alias FeudHall.Web.Token

  @commands Map.new(Management.public_commands(), &{Atom.to_string(&1), &1})
  @keys ~w(name restaurant_id stall_id cuisine recipe_id price product qty max_price_per_kunit
    profile_id main drink confirmed content_hash requirement excludes carb_ceiling_mg components
    kind recipe_version variant lines carbs_mg line_id substituted penalty deadline visit_id tray_id
    enabled start_hour end_hour cash_floor expires_at quoted_at rate shift_id selection_id item_id recipes present
    worker_id batch_id technique role target budget max_cost daily_budget min_price max_price markup_permille interval_hours
    application_id decision reason motivation policy invitation_id code tiers)a
  @by_key Map.new(@keys, &{Atom.to_string(&1), &1})
  @enums ~w(main drink dessert plant mineral meat fish dairy egg honey gelatin animal_rennet animal_fat_stock
    approved rejected prep_cook finish_cook counter quiet standard busy prime primary_only prefer_primary prefer_substitute)a
  @by_value Map.new(@enums, &{Atom.to_string(&1), &1})

  def command(%{"command_id" => id, "kind" => kind, "payload" => payload})
      when is_binary(id) and byte_size(id) in 1..64 and is_map(payload) do
    with {:ok, action} <- Map.fetch(@commands, kind),
         {:ok, fields} <- fields(payload),
         {:ok, fields} <- protected_fields(action, fields) do
      {:ok, %{command_id: id, command: {action, fields}}}
    else
      _ -> {:error, :invalid_command}
    end
  end

  def command(_), do: {:error, :invalid_command}

  def fields(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, fields} ->
      with {:ok, key} <- Map.fetch(@by_key, key),
           {:ok, value} <- field(key, value) do
        {:cont, {:ok, Map.put(fields, key, value)}}
      else
        _ -> {:halt, {:error, :invalid_fields}}
      end
    end)
  end

  defp protected_fields(:join_with_invitation, %{name: name, code: code}) do
    with {:ok, id} <- Token.verify(:invite, code), do: {:ok, %{name: name, invitation_id: id}}
  end

  defp protected_fields(:join_with_invitation, _), do: {:error, :invalid_credential}

  defp protected_fields(:redeem_invitation, %{code: code}) do
    with {:ok, id} <- Token.verify(:invite, code), do: {:ok, %{invitation_id: id}}
  end

  defp protected_fields(:redeem_invitation, _), do: {:error, :invalid_credential}

  defp protected_fields(:restore_device, %{code: code}) do
    with {:ok, id} <- Token.verify(:recovery, code), do: {:ok, %{recovery_code_id: id}}
  end

  defp protected_fields(:restore_device, _), do: {:error, :invalid_credential}
  defp protected_fields(_action, fields), do: {:ok, fields}

  defp field(key, value)
       when key in [
              :price,
              :max_price_per_kunit,
              :cash_floor,
              :max_cost,
              :rate,
              :budget,
              :daily_budget,
              :min_price,
              :max_price
            ],
       do: Money.parse(value)

  defp field(key, value) when key in [:kind, :decision, :policy, :role], do: Map.fetch(@by_value, value)

  defp field(key, values) when key in [:excludes, :tiers] and is_list(values),
    do: list(values, &Map.fetch(@by_value, &1))

  defp field(_key, value) when is_map(value), do: fields(value)
  defp field(key, value) when is_list(value), do: list(value, &field(key, &1))

  defp field(_key, value) when is_binary(value) or is_integer(value) or is_boolean(value) or is_nil(value),
    do: {:ok, value}

  defp field(_key, _value), do: {:error, :invalid_fields}

  defp list(values, convert) do
    with {:ok, reversed} <-
           Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
             case convert.(value) do
               {:ok, value} -> {:cont, {:ok, [value | acc]}}
               error -> {:halt, error}
             end
           end) do
      {:ok, Enum.reverse(reversed)}
    end
  end
end
