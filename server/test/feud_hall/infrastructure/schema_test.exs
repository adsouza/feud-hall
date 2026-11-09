defmodule FeudHall.Infrastructure.SchemaTest do
  use FeudHall.PostgresCase

  test "migrations create the event store with an append head at zero" do
    assert %{rows: [[0]]} = Repo.query!("select position from append_head where id = 1")

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query("insert into append_head (id, position) values (2, 0)")
  end
end
