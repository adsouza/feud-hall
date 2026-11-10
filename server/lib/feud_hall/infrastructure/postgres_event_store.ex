defmodule FeudHall.Infrastructure.PostgresEventStore do
  @moduledoc """
  PostgreSQL implementation of `FeudHall.Application.EventStore` (port v2).

  The store value is a handle (repo, authority scope, owner, epoch, and
  one-shot test hooks); the log itself lives in the database, so every read
  sees the committed state and `append/2` returns the same handle with its
  hooks cleared.

  One append is one transaction that takes its locks in a fixed order:

    1. the `append_head` row (`for update`);
    2. the scope's `authority` row (`for share`), compared with the handle's
       epoch, so a writer whose authority was taken over is fenced; only then
       is the head compared with `expected_position`, so a superseded writer
       (whose head is usually stale too) is told `:fenced`, not `:conflict`;
    3. the hall stream's and then the `control` stream's `stream_heads` rows
       (`for update`), compared with `expected_versions`.

  It then writes the batch row, its events (in chunks well under PostgreSQL's
  bind-parameter limit), content, projection rows, outbox intents, and the
  receipt, and advances the heads. A request without events writes only its
  receipt at the unchanged head.

  Events are stored as `EventCodec` JSON text, so player text (including NUL)
  stays escaped. A `:hall_initialized` event's catalog is stored once in
  `content`, keyed by its SHA-256 identity (the same value as
  `FeudHall.Domain.Content.hash/1`), and the stored payload carries
  `catalog_ref` instead; `read_from/2` rehydrates it. Missing or corrupt
  content, undecodable payloads, and a batch whose event rows no longer match
  the `event_count` recorded with it (`{:event_count_mismatch, recorded,
  found}`) stop reading at that batch's position.
  Receipts are stored as Base64 external term format and decoded with
  `[:safe]`, so they round-trip as the exact Elixir terms that were written.
  A stored term that cannot be decoded (one naming an atom this build does not
  define, as a newer release could write) is an error, never a raise:
  `receipt/2` returns `{:error, {:undecodable_receipt, command_id}}`,
  `outbox/1` `{:error, {:undecodable_outbox, dedupe_key}}`, and content stops
  reading as `{:undecodable_content, ref}`. `FeudHall.App` loads every
  application module at start-up, so atoms this build does define are found.

  The `:lock_timeout_ms` option bounds how long an append waits for any of
  those locks (`set local lock_timeout` at the start of its transaction, so the
  connection's own setting is untouched afterwards); without it the
  connection's configured `lock_timeout` applies. A writer that hangs while
  holding the head lock therefore makes the next writer fail as `:unavailable`
  within that bound instead of queueing behind it indefinitely.

  Connection failures and lock timeouts are `:unavailable`. A connection
  failure after the transaction body finished (while committing) cannot prove
  a rollback, so it is reported as `:unknown_outcome`.

  `fail_next/2` arms a one-shot injected failure for the next append:
  `:before_commit` aborts the transaction just before commit (`:unavailable`),
  `:unavailable` and `:fenced` refuse without touching the database, and
  `:lost_reply` commits but reports `:unknown_outcome`.
  """

  @behaviour FeudHall.Application.EventStore

  alias FeudHall.Application.{EventStore, Replay}
  alias FeudHall.Application.Projections.Balances
  alias FeudHall.Domain.Hall.Evolver
  alias FeudHall.Infrastructure.{EventCodec, Snapshot}

  @control "control"
  @chunk 1_000
  @timeout 60_000
  @default_hooks %{before_commit: nil, lost_reply: false, refuse: nil}
  @unavailable_codes [:lock_not_available, :query_canceled, :admin_shutdown, :crash_shutdown, :cannot_connect_now]
  @accounts Map.new(Evolver.ledger_accounts(), &{Atom.to_string(&1), &1})

  @enforce_keys [:repo, :scope]
  defstruct repo: nil, scope: nil, owner: nil, epoch: nil, lock_timeout_ms: nil, hooks: @default_hooks

  @type t :: %__MODULE__{
          repo: module(),
          scope: String.t(),
          owner: String.t() | nil,
          epoch: pos_integer() | nil,
          lock_timeout_ms: pos_integer() | nil,
          hooks: %{before_commit: (-> any()) | nil, lost_reply: boolean(), refuse: nil | :fenced | :unavailable}
        }

  @doc "A handle for `scope` on `repo`. Options: `:owner`, `:epoch`, `:lock_timeout_ms`, `:hooks`."
  def new(repo, scope, opts \\ []) when is_atom(repo) and is_binary(scope) do
    lock_timeout_ms = Keyword.get(opts, :lock_timeout_ms)

    unless is_nil(lock_timeout_ms) or (is_integer(lock_timeout_ms) and lock_timeout_ms > 0) do
      raise ArgumentError, "lock_timeout_ms must be a positive integer, got: #{inspect(lock_timeout_ms)}"
    end

    %__MODULE__{
      repo: repo,
      scope: scope,
      owner: Keyword.get(opts, :owner),
      epoch: Keyword.get(opts, :epoch),
      lock_timeout_ms: lock_timeout_ms,
      hooks: Map.merge(@default_hooks, Map.new(Keyword.get(opts, :hooks, %{})))
    }
  end

  @doc """
  Whether a PostgreSQL error code (as Postgrex names it, e.g. `:admin_shutdown`)
  means storage is unavailable (a lock timeout, cancellation, or shutdown) rather
  than a defect. The adapter reports those as `:unavailable`; callers that shield
  raised driver errors use the same set.
  """
  @spec unavailable_code?(term()) :: boolean()
  def unavailable_code?(code), do: code in @unavailable_codes

  @doc "Arms a one-shot failure for the next append."
  def fail_next(store, :before_commit),
    do: put_hook(store, :before_commit, fn -> raise DBConnection.ConnectionError, "injected failure before commit" end)

  def fail_next(store, :lost_reply), do: put_hook(store, :lost_reply, true)
  def fail_next(store, mode) when mode in [:fenced, :unavailable], do: put_hook(store, :refuse, mode)

  defp put_hook(store, key, value), do: %{store | hooks: Map.put(store.hooks, key, value)}
  defp clear_hooks(store), do: %{store | hooks: @default_hooks}

  @doc "The committed head position; `{:error, :unavailable}` when storage cannot be reached."
  @impl true
  def head(store) do
    sql = "select position from append_head where id = 1"
    with {:ok, %{rows: [[position]]}} <- attempt(fn -> store.repo.query!(sql) end), do: position
  end

  @doc "Stream versions; `{:error, :unavailable}` when storage cannot be reached."
  @impl true
  def stream_versions(store, hall_stream) do
    sql = "select stream, version from stream_heads where stream = any($1)"

    with {:ok, %{rows: rows}} <-
           attempt(fn -> store.repo.query!(sql, [Enum.reject([hall_stream, @control], &is_nil/1)]) end) do
      versions = Map.new(rows, fn [stream, version] -> {stream, version} end)
      %{hall: if(hall_stream, do: Map.get(versions, hall_stream, 0), else: 0), control: Map.get(versions, @control, 0)}
    end
  end

  # --- append ---------------------------------------------------------------

  @impl true
  def append(%{hooks: %{refuse: mode}} = store, _request) when mode != nil, do: {:error, mode, clear_hooks(store)}
  def append(%{epoch: nil} = store, _request), do: {:error, :fenced, clear_hooks(store)}

  def append(store, request) do
    hooks = store.hooks
    store = clear_hooks(store)

    with :ok <- EventStore.validate_request(request),
         {:ok, position} <- transact(store, request, hooks) do
      if hooks.lost_reply, do: {:error, :unknown_outcome, store}, else: {:ok, store, position}
    else
      :invalid_request -> {:error, :invalid_request, store}
      {:error, reason} -> {:error, reason, store}
    end
  end

  # Runs the append transaction and classifies failures. `committing` is set once
  # the transaction body has finished, so a connection error after it (during
  # COMMIT) is an unknown outcome rather than a proven rollback.
  defp transact(store, request, hooks) do
    committing = make_ref()

    try do
      store.repo.transaction(fn -> write(store, request, hooks, committing) end, timeout: @timeout)
    rescue
      DBConnection.ConnectionError ->
        if Process.get(committing), do: {:error, :unknown_outcome}, else: {:error, :unavailable}

      error in Postgrex.Error ->
        classify(error, __STACKTRACE__)
    else
      {:ok, position} -> {:ok, position}
      {:error, reason} when reason in [:conflict, :fenced] -> {:error, reason}
      {:error, :rollback} -> {:error, :unavailable}
    after
      Process.delete(committing)
    end
  end

  defp classify(%Postgrex.Error{postgres: %{code: code}}, _stack) when code in @unavailable_codes,
    do: {:error, :unavailable}

  defp classify(%Postgrex.Error{postgres: %{code: :unique_violation, table: table}}, _stack)
       when table in ["receipts", "batches", "outbox"],
       do: {:error, :conflict}

  defp classify(error, stack), do: reraise(error, stack)

  defp write(store, request, hooks, committing) do
    repo = store.repo
    set_lock_timeout(repo, store.lock_timeout_ms)
    position = lock_head(repo)
    # Fencing is judged before the head: a superseded owner's head is usually stale too (the new
    # owner's recovery appended), and it must learn it is fenced rather than retry a conflict.
    if authority_epoch(repo, store.scope) != store.epoch, do: repo.rollback(:fenced)
    if position != request.expected_position, do: repo.rollback(:conflict)
    versions = lock_streams(repo, request.hall_stream)
    if versions != request.expected_versions, do: repo.rollback(:conflict)
    if receipt_exists?(repo, request.command_id), do: repo.rollback(:conflict)
    if outbox_key_taken?(repo, request.outbox), do: repo.rollback(:conflict)

    %{events: events, control_events: control_events} = request
    batch? = events != [] or control_events != []
    position = if batch?, do: position + 1, else: position

    if batch? do
      insert_batch(repo, request, position, versions)
      repo.query!("update append_head set position = $1 where id = 1", [position])
      advance_stream(repo, request.hall_stream, versions.hall + length(events), events)
      advance_stream(repo, @control, versions.control + length(control_events), control_events)
    end

    apply_projection_rows(repo, request.projection_rows, position)
    insert_outbox(repo, request, position)
    insert_receipt(repo, request, position)

    if hooks.before_commit, do: hooks.before_commit.()
    Process.put(committing, true)
    position
  end

  # `set` takes no bind parameters; the value is a validated positive integer (milliseconds).
  defp set_lock_timeout(_repo, nil), do: :ok
  defp set_lock_timeout(repo, ms) when is_integer(ms) and ms > 0, do: repo.query!("set local lock_timeout = #{ms}")

  defp lock_head(repo) do
    %{rows: [[position]]} = repo.query!("select position from append_head where id = 1 for update")
    position
  end

  defp authority_epoch(repo, scope) do
    case repo.query!("select epoch from authority where scope = $1 for share", [scope]) do
      %{rows: [[epoch]]} -> epoch
      %{rows: []} -> nil
    end
  end

  # Hall stream first, then control: the fixed lock order every writer uses.
  defp lock_streams(repo, hall_stream) do
    %{hall: if(hall_stream, do: lock_stream(repo, hall_stream), else: 0), control: lock_stream(repo, @control)}
  end

  defp lock_stream(repo, stream) do
    repo.query!("insert into stream_heads (stream, version) values ($1, 0) on conflict do nothing", [stream])
    %{rows: [[version]]} = repo.query!("select version from stream_heads where stream = $1 for update", [stream])
    version
  end

  defp advance_stream(_repo, _stream, _version, []), do: :ok

  defp advance_stream(repo, stream, version, _events),
    do: repo.query!("update stream_heads set version = $2 where stream = $1", [stream, version])

  defp receipt_exists?(repo, command_id),
    do: repo.query!("select 1 from receipts where command_id = $1", [command_id]).num_rows > 0

  defp insert_batch(repo, request, position, versions) do
    %{command_id: command_id, context: context} = request

    repo.query!("insert into batches (position, command_id, hall_ms, event_count) values ($1, $2, $3, $4)", [
      position,
      command_id,
      context.hall_ms,
      length(request.events) + length(request.control_events)
    ])

    envelope = %{
      position: position,
      actor: actor_label(context.actor),
      causation_id: command_id,
      correlation_id: context.correlation_id,
      content_hash: context.content_hash,
      hall_ms: context.hall_ms
    }

    hall = Enum.with_index(request.events, &{&1, request.hall_stream, versions.hall + &2 + 1})
    control = Enum.with_index(request.control_events, &{&1, @control, versions.control + &2 + 1})

    (hall ++ control)
    |> Enum.with_index()
    |> Enum.map(fn {{event, stream, version}, order} -> event_row(repo, event, stream, version, order, envelope) end)
    |> Enum.chunk_every(@chunk)
    |> Enum.each(&repo.insert_all("events", &1))
  end

  defp event_row(repo, event, stream, version, order, envelope) do
    Map.merge(envelope, %{
      event_id: "#{envelope.position}:#{order}",
      batch_order: order,
      stream: stream,
      stream_version: version,
      type: Atom.to_string(event.type),
      schema: EventCodec.schema(),
      payload: EventCodec.encode!(stored_payload(repo, event))
    })
  end

  # The catalog is stored once per content identity; the event references it.
  defp stored_payload(repo, %{type: type, catalog: catalog} = event)
       when type in [:hall_initialized, :hall_simulation_upgraded, :hall_catalog_expanded] do
    body = :erlang.term_to_binary(catalog, [:deterministic])
    ref = content_hash(body)

    repo.query!("insert into content (content_hash, body) values ($1, $2) on conflict do nothing", [ref, body])
    event |> Map.delete(:catalog) |> Map.put(:catalog_ref, ref)
  end

  defp stored_payload(_repo, event), do: event

  defp content_hash(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

  defp actor_label({kind, id}) when kind in [:principal, :npc, :system, :device], do: "#{kind}:#{id}"
  defp actor_label(other), do: inspect(other)

  # Rows apply in order (later rows for the same key win), so they are folded
  # to one final operation per key before the bulk upserts and deletes.
  defp apply_projection_rows(_repo, [], _position), do: :ok

  defp apply_projection_rows(repo, rows, position) do
    final =
      Enum.reduce(rows, %{}, fn
        {:balance, r, account, amount}, acc ->
          Map.put(acc, {:balance, r, account}, %{
            restaurant_id: r,
            account: Atom.to_string(account),
            amount: amount,
            position: position
          })

        {:stock, r, product, on_hand, reserved}, acc ->
          Map.put(acc, {:stock, r, product}, %{
            restaurant_id: r,
            product: product,
            on_hand: on_hand,
            reserved: reserved,
            position: position
          })

        {:delete_balance, r, account}, acc ->
          Map.put(acc, {:balance, r, account}, :delete)

        {:delete_stock, r, product}, acc ->
          Map.put(acc, {:stock, r, product}, :delete)
      end)

    {deletes, upserts} = Enum.split_with(final, fn {_key, value} -> value == :delete end)
    {balances, stock} = Enum.split_with(upserts, fn {{table, _, _}, _} -> table == :balance end)

    for {{:balance, r, account}, :delete} <- deletes do
      repo.query!("delete from restaurant_balances where restaurant_id = $1 and account = $2", [
        r,
        Atom.to_string(account)
      ])
    end

    for {{:stock, r, product}, :delete} <- deletes do
      repo.query!("delete from restaurant_stock where restaurant_id = $1 and product = $2", [r, product])
    end

    upsert(repo, "restaurant_balances", Enum.map(balances, &elem(&1, 1)), [:amount, :position], [
      :restaurant_id,
      :account
    ])

    upsert(repo, "restaurant_stock", Enum.map(stock, &elem(&1, 1)), [:on_hand, :reserved, :position], [
      :restaurant_id,
      :product
    ])
  end

  defp upsert(repo, table, rows, fields, target) do
    rows
    |> Enum.chunk_every(@chunk)
    |> Enum.each(&repo.insert_all(table, &1, on_conflict: {:replace, fields}, conflict_target: target))
  end

  # Checked under the head lock, so no concurrent writer can slip a key in between.
  defp outbox_key_taken?(_repo, []), do: false

  defp outbox_key_taken?(repo, outbox) do
    keys = Enum.map(outbox, & &1.dedupe_key)

    length(Enum.uniq(keys)) != length(keys) or
      repo.query!("select 1 from outbox where dedupe_key = any($1)", [keys]).num_rows > 0
  end

  # Outbox payloads are Base64 external terms (like receipts), decoded with `[:safe]`.
  defp insert_outbox(_repo, %{outbox: []}, _position), do: :ok

  defp insert_outbox(repo, request, position) do
    rows =
      Enum.map(request.outbox, fn intent ->
        %{
          dedupe_key: intent.dedupe_key,
          command_id: request.command_id,
          position: position,
          kind: Atom.to_string(intent.kind),
          payload: encode_term(intent.payload)
        }
      end)

    rows
    |> Enum.chunk_every(@chunk)
    |> Enum.each(&repo.insert_all("outbox", &1))
  end

  defp insert_receipt(repo, request, position) do
    %{command_id: command_id, receipt: receipt} = request

    repo.query!("insert into receipts (command_id, fingerprint, body, position) values ($1, $2, $3, $4)", [
      command_id,
      Map.fetch!(receipt, :fingerprint),
      encode_term(receipt),
      position
    ])
  end

  defp encode_term(term), do: term |> :erlang.term_to_binary() |> Base.encode64()

  defp decode_term(text) do
    case Base.decode64(text) do
      {:ok, binary} -> safe_term(binary)
      :error -> :error
    end
  end

  # `[:safe]` never creates atoms: a term naming one this build does not define is refused.
  defp safe_term(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    ArgumentError -> :error
  end

  # --- reads ----------------------------------------------------------------

  @doc "Every batch after `after_position`; `{:error, :unavailable}` when storage cannot be reached."
  @impl true
  def read_from(store, after_position) do
    with {:ok, result} <- attempt(fn -> read_after(store.repo, after_position, nil) end), do: result
  end

  @impl true
  def guest_visit_events(store, stream, principal, head, before, limit) do
    with {:ok, %{rows: rows}} <-
           attempt(fn ->
             store.repo.query!(
               """
               select a.stream_version, a.payload, f.payload,
                 coalesce(t.at, case when exists (
                   select 1 from events c where c.position = f.position and c.type = 'clock_advanced'
                 ) then coalesce(previous.hall_ms, 0) else f.hall_ms end),
                 array(
                   select p.payload from events p
                   where p.stream = a.stream and p.type in ('tray_accepted', 'dessert_accepted')
                     and p.payload::json #>> '{e,visit_id}' = a.payload::json #>> '{e,visit_id}'
                     and p.stream_version between a.stream_version and f.stream_version
                   order by p.stream_version
                 )
               from events a
               join events f on f.stream = a.stream and f.type = 'visit_finalized'
                 and f.payload::json #>> '{e,visit_id}' = a.payload::json #>> '{e,visit_id}'
                 and f.stream_version between a.stream_version and $3
               left join batches previous on previous.position = f.position - 1
               left join lateral (
                 select (c.payload::json #>> '{e,to}')::bigint as at
                 from events c where c.position = f.position and c.type = 'clock_advanced'
                   and c.batch_order < f.batch_order
                 order by c.batch_order desc limit 1
               ) t on true
               where a.stream = $1 and a.type = 'visit_admitted'
                 and a.payload::json #>> '{e,source,$a}' = 'guest'
                 and a.payload::json #>> '{e,principal}' = $2
                 and a.stream_version < $4 and a.stream_version <= $3
               order by a.stream_version desc limit $5
               """,
               [stream, principal, head, before, limit],
               timeout: 1_000
             )
           end) do
      Enum.reduce_while(rows, {:ok, []}, fn [version, admit, final, at, accepted], {:ok, acc} ->
        with {:ok, admitted} <- EventCodec.decode(admit),
             {:ok, finalized} <- EventCodec.decode(final),
             {:ok, orders} <- decode_accepted_orders(accepted) do
          {:cont, {:ok, [%{version: version, admitted: admitted, finalized: finalized, at: at, orders: orders} | acc]}}
        else
          {:error, _} -> {:halt, {:error, :history_unavailable}}
        end
      end)
      |> case do
        {:ok, visits} -> {:ok, Enum.reverse(visits)}
        error -> error
      end
    end
  end

  @impl true
  def guest_tasted_recipes(store, stream, principal, head) do
    with {:ok, %{rows: rows}} <-
           attempt(fn ->
             store.repo.query!(
               """
               select distinct course.data ->> 'recipe_id'
               from events a
               join events t on t.stream = a.stream and t.type = 'tray_accepted'
                 and t.payload::json #>> '{e,visit_id}' = a.payload::json #>> '{e,visit_id}'
                 and t.stream_version between a.stream_version and $3
               join events s on s.stream = a.stream and s.type = 'tray_served'
                 and s.payload::json #>> '{e,tray_id}' = t.payload::json #>> '{e,tray_id}'
                 and s.stream_version between t.stream_version and $3
               cross join lateral json_array_elements(t.payload::json #> '{e,components}') course(data)
               where a.stream = $1 and a.type = 'visit_admitted'
                 and a.payload::json #>> '{e,source,$a}' = 'guest'
                 and a.payload::json #>> '{e,principal}' = $2
                 and a.stream_version <= $3 and course.data #>> '{kind,$a}' = 'main'
               """,
               [stream, principal, head],
               timeout: 1_000
             )
           end) do
      {:ok, Enum.map(rows, &hd/1)}
    end
  end

  defp decode_accepted_orders(payloads) do
    Enum.reduce_while(payloads, {:ok, []}, fn payload, {:ok, acc} ->
      case EventCodec.decode(payload) do
        {:ok, %{type: :tray_accepted, components: orders}} -> {:cont, {:ok, acc ++ orders}}
        {:ok, %{type: :dessert_accepted, order: order}} -> {:cont, {:ok, acc ++ [order]}}
        _ -> {:halt, {:error, :history_unavailable}}
      end
    end)
  end

  @doc """
  Reads at most `limit` batches (all when `nil`) after `after_position`, in position order, decoded
  like `read_from/2`. Lets an asynchronous consumer page through the log without loading it whole.
  """
  @spec read_after(module(), non_neg_integer(), pos_integer() | nil) :: {:ok, [map()]} | {:error, term()}
  def read_after(repo, after_position, limit) do
    %{rows: batches} =
      repo.query!(
        """
        select b.position, b.command_id, b.hall_ms, b.event_count, previous.hall_ms
        from batches b left join batches previous on previous.position = b.position - 1
        where b.position > $1 order by b.position limit $2
        """,
        [after_position, limit]
      )

    upper = batches |> List.last() |> then(&(&1 && hd(&1)))

    %{rows: event_rows} =
      repo.query!(
        "select position, stream, payload from events where position > $1 and position <= $2 " <>
          "order by position, batch_order",
        [after_position, upper || after_position]
      )

    events_by_position = Enum.group_by(event_rows, &hd/1, &tl/1)

    batches
    |> Enum.reduce_while({[], %{}}, fn [position, command_id, hall_ms, event_count, start_hall_ms], {acc, content} ->
      rows = Map.get(events_by_position, position, [])

      result =
        if length(rows) == event_count,
          do: decode_batch(repo, rows, content),
          else: {:error, {:event_count_mismatch, event_count, length(rows)}}

      case result do
        {:ok, events, control_events, content} ->
          batch = %{
            position: position,
            command_id: command_id,
            hall_ms: hall_ms,
            start_hall_ms: start_hall_ms,
            events: events,
            control_events: control_events
          }

          {:cont, {[batch | acc], content}}

        {:error, reason} ->
          {:halt, {:error, {:undecodable, position, reason}}}
      end
    end)
    |> case do
      {:error, _} = error -> error
      {batches, _content} -> {:ok, Enum.reverse(batches)}
    end
  end

  defp decode_batch(repo, rows, content) do
    Enum.reduce_while(rows, {:ok, [], [], content}, fn [stream, payload], {:ok, hall, control, content} ->
      with {:ok, event} <- EventCodec.decode(payload),
           {:ok, event, content} <- rehydrate(repo, event, content) do
        if stream == @control,
          do: {:cont, {:ok, hall, [event | control], content}},
          else: {:cont, {:ok, [event | hall], control, content}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, hall, control, content} -> {:ok, Enum.reverse(hall), Enum.reverse(control), content}
      error -> error
    end
  end

  defp rehydrate(repo, %{catalog_ref: ref} = event, content) do
    with {:ok, catalog, content} <- fetch_content(repo, ref, content) do
      {:ok, event |> Map.delete(:catalog_ref) |> Map.put(:catalog, catalog), content}
    end
  end

  defp rehydrate(_repo, event, content), do: {:ok, event, content}

  defp fetch_content(_repo, ref, %{} = content) when is_map_key(content, ref),
    do: {:ok, Map.fetch!(content, ref), content}

  defp fetch_content(repo, ref, content) do
    case repo.query!("select body from content where content_hash = $1", [ref]) do
      %{rows: [[body]]} ->
        with true <- content_hash(body) == ref || {:error, {:corrupt_content, ref}},
             {:ok, catalog} <- safe_term(body) do
          {:ok, catalog, Map.put(content, ref, catalog)}
        else
          {:error, _} = error -> error
          :error -> {:error, {:undecodable_content, ref}}
        end

      %{rows: []} ->
        {:error, {:missing_content, ref}}
    end
  end

  @impl true
  def receipt(store, command_id) do
    sql = "select body, position from receipts where command_id = $1"

    case attempt(fn -> store.repo.query!(sql, [command_id]) end) do
      {:ok, %{rows: [[body, position]]}} ->
        case decode_term(body) do
          {:ok, %{} = receipt} -> {:ok, Map.put(receipt, :position, position)}
          _undecodable -> {:error, {:undecodable_receipt, command_id}}
        end

      {:ok, %{rows: []}} ->
        :none

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def projection(store, :balances) do
    %{rows: rows} = store.repo.query!("select restaurant_id, account, amount, position from restaurant_balances")

    rows
    |> Enum.map(fn [r, account, amount, position] ->
      %{restaurant_id: r, account: Map.fetch!(@accounts, account), amount: amount, position: position}
    end)
    |> Enum.sort_by(&{&1.restaurant_id, &1.account})
  end

  def projection(store, :stock) do
    %{rows: rows} =
      store.repo.query!("select restaurant_id, product, on_hand, reserved, position from restaurant_stock")

    rows
    |> Enum.map(fn [r, product, on_hand, reserved, position] ->
      %{restaurant_id: r, product: product, on_hand: on_hand, reserved: reserved, position: position}
    end)
    |> Enum.sort_by(&{&1.restaurant_id, &1.product})
  end

  @outbox_kinds Map.new(EventStore.outbox_kinds(), &{Atom.to_string(&1), &1})

  @impl true
  def outbox(store) do
    %{rows: rows} =
      store.repo.query!("select dedupe_key, command_id, position, kind, payload from outbox order by id")

    rows
    |> Enum.reduce_while([], fn [dedupe_key, command_id, position, kind, payload], acc ->
      with {:ok, kind} <- Map.fetch(@outbox_kinds, kind),
           {:ok, payload} <- decode_term(payload) do
        intent = %{dedupe_key: dedupe_key, command_id: command_id, position: position, kind: kind, payload: payload}
        {:cont, [intent | acc]}
      else
        :error -> {:halt, {:error, {:undecodable_outbox, dedupe_key}}}
      end
    end)
    |> case do
      {:error, _} = error -> error
      intents -> Enum.reverse(intents)
    end
  end

  @doc """
  Rebuilds `restaurant_balances` and `restaurant_stock` from the event log.

  One transaction holds the append-head lock (so no batch lands mid-rebuild),
  checks and folds every committed batch before replacing both tables, and writes every
  account and product of the folded state. Rows carry the head position they
  were rebuilt at, not the batch that last changed them. Returns
  `{:error, :unavailable}` when storage cannot be reached and `{:error, reason}`
  when a stored event cannot be decoded; neither leaves a partial rebuild.
  """
  @spec rebuild_projections(t()) :: :ok | {:error, term()}
  def rebuild_projections(store) do
    repo = store.repo

    result =
      attempt(fn ->
        repo.transaction(
          fn ->
            set_lock_timeout(repo, store.lock_timeout_ms)
            head = lock_head(repo)

            case Replay.load(__MODULE__, store, head: head) do
              {:ok, %{hall: state}} ->
                repo.query!("truncate restaurant_balances, restaurant_stock")
                apply_projection_rows(repo, Balances.changes(nil, state, head), head)

              {:error, reason} ->
                repo.rollback(reason)
            end
          end,
          timeout: @timeout
        )
      end)

    case result do
      {:ok, {:ok, _}} -> :ok
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, _} = error -> error
    end
  end

  # --- authority and snapshots -------------------------------------------

  @impl true
  def acquire_authority(store, scope, owner, expected_epoch \\ nil)

  def acquire_authority(store, scope, owner, nil) do
    sql = """
    insert into authority (scope, owner, epoch) values ($1, $2, 1)
    on conflict (scope) do update set owner = excluded.owner, epoch = authority.epoch + 1
    returning epoch
    """

    with {:ok, %{rows: [[epoch]]}} <- attempt(fn -> store.repo.query!(sql, [scope, owner]) end) do
      {:ok, %{store | scope: scope, owner: owner, epoch: epoch}, epoch}
    end
  end

  # One conditional update: the row lock makes the compare and the bump atomic against any
  # concurrent acquisition. The row may also show this same owner at exactly `expected + 1`: that
  # is this owner's own acquisition whose reply was lost, so it bumps again from there. No row means
  # the epoch moved on to someone else (or further), or the scope was never held.
  def acquire_authority(store, scope, owner, expected_epoch) when is_integer(expected_epoch) do
    sql = """
    update authority set owner = $2, epoch = epoch + 1
    where scope = $1 and (epoch = $3 or (owner = $2 and epoch = $3 + 1))
    returning epoch
    """

    case attempt(fn -> store.repo.query!(sql, [scope, owner, expected_epoch]) end) do
      {:ok, %{rows: [[epoch]]}} -> {:ok, %{store | scope: scope, owner: owner, epoch: epoch}, epoch}
      {:ok, %{rows: []}} -> {:error, :fenced}
      {:error, _} = error -> error
    end
  end

  @impl true
  def held_epoch(store), do: store.epoch

  # Its own short transaction: it never touches `append_head`, so saving a snapshot never waits
  # on an in-flight append. The evolution version is read from the (checksummed) binary; an
  # unreadable binary is stored as evolution 0 and rejected later by `Snapshot.load/1`.
  @impl true
  def save_snapshot(store, position, body) when is_binary(body) do
    sql = "insert into snapshots (position, evolution, body) values ($1, $2, $3) returning id"
    evolution = Snapshot.evolution_of(body) || 0

    result =
      attempt(fn ->
        {:ok, id} =
          store.repo.transaction(fn ->
            %{rows: [[id]]} = store.repo.query!(sql, [position, evolution, body])
            id
          end)

        id
      end)

    with {:ok, id} <- result, do: {:ok, store, id}
  end

  @impl true
  def mark_snapshot_verified(store, id) when is_integer(id) do
    case store.repo.query!("update snapshots set verified = true where id = $1", [id]) do
      %{num_rows: 1} -> {:ok, store}
      %{num_rows: 0} -> {:error, :unknown_snapshot}
    end
  end

  def mark_snapshot_verified(_store, _id), do: {:error, :unknown_snapshot}

  @doc "Stored snapshots, newest first (by position, then id); `{:error, :unavailable}` when storage cannot be reached."
  @impl true
  def snapshots(store) do
    sql = "select id, position, body, verified from snapshots order by position desc, id desc"

    with {:ok, %{rows: rows}} <- attempt(fn -> store.repo.query!(sql) end) do
      Enum.map(rows, fn [id, position, body, verified] ->
        %{id: id, position: position, body: body, verified: verified}
      end)
    end
  end

  @doc """
  Deletes snapshots older than the `keep_verified` newest verified ones (newest by position, then
  id), unverified ones included. Every snapshot at or after the oldest kept verified one stays,
  so an unverified snapshot newer than it survives. With fewer than `keep_verified` verified
  snapshots nothing is deleted.
  """
  @spec prune_snapshots(t(), pos_integer()) :: {:ok, t()} | {:error, :unavailable}
  def prune_snapshots(store, keep_verified \\ 2) when is_integer(keep_verified) and keep_verified > 0 do
    sql = """
    delete from snapshots
    where (position, id) < (
      select position, id from snapshots where verified
      order by position desc, id desc offset $1 limit 1
    )
    """

    with {:ok, _} <- attempt(fn -> store.repo.query!(sql, [keep_verified - 1]) end), do: {:ok, store}
  end

  defp attempt(fun) do
    {:ok, fun.()}
  rescue
    DBConnection.ConnectionError -> {:error, :unavailable}
    error in Postgrex.Error -> classify(error, __STACKTRACE__)
  end
end
