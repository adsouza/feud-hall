defmodule FeudHall.Domain.NpcActorTest do
  use ExUnit.Case, async: true

  alias FeudHall.Domain.Content.SliceCatalog
  alias FeudHall.Domain.Hall

  @create {:create_restaurant, %{restaurant_id: "r1", stall_id: "s001", name: "Budget", cuisine: "mexican"}}

  defp ctx(actor, id), do: %{command_id: id, actor: actor}

  defp hall do
    {:ok, state, _} =
      Hall.execute(
        nil,
        {:initialize_hall, %{hall_id: "h1", catalog: SliceCatalog.catalog()}},
        ctx({:system, :admin}, "init")
      )

    state
  end

  defp created(actor) do
    {:ok, state, events} = Hall.execute(hall(), @create, ctx(actor, "create"))
    {state, events}
  end

  test "an NPC owns and operates its restaurant like a principal" do
    {state, [created | _]} = created({:npc, "budget"})
    assert created.owner_kind == :npc
    assert state.restaurants["r1"].owner_kind == :npc
    assert state.owners == %{{:npc, "budget"} => "r1"}

    assert {:ok, [%{type: :stall_opened}]} =
             Hall.decide(state, {:open_stall, %{stall_id: "s001"}}, ctx({:npc, "budget"}, "o1"))

    assert {:error, :forbidden} =
             Hall.decide(state, {:open_stall, %{stall_id: "s001"}}, ctx({:principal, "budget"}, "o2"))
  end

  test "a principal's restaurant is not operable by an NPC with the same id" do
    {state, [created | _]} = created({:principal, "budget"})
    assert created.owner_kind == :principal
    assert {:error, :forbidden} = Hall.decide(state, {:open_stall, %{stall_id: "s001"}}, ctx({:npc, "budget"}, "o1"))
    assert {:ok, _} = Hall.decide(state, {:open_stall, %{stall_id: "s001"}}, ctx({:principal, "budget"}, "o2"))
  end

  test "a principal and an NPC with the same id string own separate ventures" do
    {state, _} = created({:principal, "budget"})

    other = {:create_restaurant, %{restaurant_id: "r2", stall_id: "s002", name: "Other", cuisine: "mexican"}}
    assert {:ok, state, _} = Hall.execute(state, other, ctx({:npc, "budget"}, "create2"))
    assert state.owners == %{{:principal, "budget"} => "r1", {:npc, "budget"} => "r2"}

    again = {:create_restaurant, %{restaurant_id: "r3", stall_id: "s003", name: "Third", cuisine: "mexican"}}
    assert {:error, :venture_already_active} = Hall.decide(state, again, ctx({:npc, "budget"}, "create3"))
    assert {:error, :venture_already_active} = Hall.decide(state, again, ctx({:principal, "budget"}, "create4"))
  end

  test "legacy restaurant_created events without owner_kind replay as principal-owned" do
    legacy = %{
      type: :restaurant_created,
      restaurant_id: "r1",
      owner: "alice",
      name: "Casa",
      cuisine: "mexican",
      starter_recipe: "bean_tacos",
      stall_id: "s001"
    }

    state = Hall.evolve(hall(), legacy)
    assert state.restaurants["r1"].owner_kind == :principal
    assert state.owners == %{{:principal, "alice"} => "r1"}
    assert {:ok, _} = Hall.decide(state, {:open_stall, %{stall_id: "s001"}}, ctx({:principal, "alice"}, "o1"))
  end
end
