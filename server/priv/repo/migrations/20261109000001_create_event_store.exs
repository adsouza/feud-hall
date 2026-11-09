defmodule FeudHall.Infrastructure.Repo.Migrations.CreateEventStore do
  use Ecto.Migration

  def change do
    execute(
      """
      create table append_head (
        id smallint primary key check (id = 1),
        position bigint not null
      )
      """,
      "drop table append_head"
    )

    execute(
      "create table stream_heads (stream text primary key, version bigint not null)",
      "drop table stream_heads"
    )

    execute(
      "create table authority (scope text primary key, owner text not null, epoch bigint not null)",
      "drop table authority"
    )

    execute(
      """
      create table batches (
        position bigint primary key,
        command_id text not null unique,
        hall_ms bigint,
        inserted_at timestamptz not null default now()
      )
      """,
      "drop table batches"
    )

    execute(
      """
      create table events (
        event_id text primary key,
        position bigint not null references batches,
        batch_order int not null,
        stream text not null,
        stream_version bigint not null,
        type text not null,
        schema int not null,
        payload text not null,
        actor text not null,
        causation_id text not null,
        correlation_id text not null,
        content_hash text,
        hall_ms bigint,
        unique (stream, stream_version),
        unique (position, batch_order)
      )
      """,
      "drop table events"
    )

    execute(
      """
      create table receipts (
        command_id text primary key,
        fingerprint text not null,
        body text not null,
        position bigint not null
      )
      """,
      "drop table receipts"
    )

    execute(
      """
      create table outbox (
        id bigserial primary key,
        dedupe_key text not null unique,
        command_id text not null,
        position bigint not null,
        kind text not null,
        payload text not null
      )
      """,
      "drop table outbox"
    )

    execute(
      "create table content (content_hash text primary key, body bytea not null)",
      "drop table content"
    )

    execute(
      """
      create table snapshots (
        id bigserial primary key,
        position bigint not null,
        evolution int not null,
        body bytea not null,
        verified boolean not null default false
      )
      """,
      "drop table snapshots"
    )

    execute(
      """
      create table restaurant_balances (
        restaurant_id text,
        account text,
        amount bigint not null,
        position bigint not null,
        primary key (restaurant_id, account)
      )
      """,
      "drop table restaurant_balances"
    )

    execute(
      """
      create table restaurant_stock (
        restaurant_id text,
        product text,
        on_hand bigint not null,
        reserved bigint not null,
        position bigint not null,
        primary key (restaurant_id, product)
      )
      """,
      "drop table restaurant_stock"
    )

    execute(
      """
      create table daily_activity (
        day int,
        restaurant_id text,
        visits_admitted int not null,
        trays_accepted int not null,
        primary key (day, restaurant_id)
      )
      """,
      "drop table daily_activity"
    )

    execute(
      "create table projector_checkpoints (name text primary key, position bigint not null)",
      "drop table projector_checkpoints"
    )

    execute("insert into append_head (id, position) values (1, 0)", "")
  end
end
