# Measures customers at sparse-hall settings. Run from server/:
#
#   mix run --no-start scripts/customer_sim.exs -- --run a|b --tuning current|chosen|PATH \
#     --days N --seed S [--via init|retune] [--hours START-END] [--cuisine ID] \
#     [--extra-stalls N] [--set KEY=VALUE ...] [--json PATH]
#
# A real hall authority runs in memory (no web endpoint, no database) with a
# manual clock, ticked once per service second as the live hall is. The only
# writes are commands: the hall's own initialisation, the computer-run owners
# the authority creates, and in run A one reference owner (plus `--extra-stalls`
# more owners set up the same way) playing through the same management boundary
# a client uses. Everything measured is read from the authority's committed
# state and events.

defmodule FeudHall.CustomerSim.Clock do
  @moduledoc false
  @behaviour FeudHall.Application.MonotonicClock

  @impl true
  def now_ms(clock), do: :atomics.get(clock, 1)
end

defmodule FeudHall.CustomerSim.Sink do
  @moduledoc false
  # Keeps only the diagnostics that make a run untrustworthy, in a public ETS table owned by the driver.
  @behaviour FeudHall.Application.Diagnostics

  @kept [:npc_planner_failed, :storage_failure, :scheduler_gap, :fenced, :snapshot_failed]

  @impl true
  def emit(table, %{name: name, fields: fields}) when name in @kept do
    :ets.insert(table, {System.unique_integer([:monotonic]), name, fields})
    :ok
  end

  def emit(_table, _record), do: :ok

  def records(table),
    do: table |> :ets.tab2list() |> Enum.sort() |> Enum.map(fn {_, name, fields} -> {name, fields} end)
end

defmodule FeudHall.CustomerSim.Store do
  @moduledoc """
  The in-memory event store, unchanged, plus a read-only tally of the money
  each committed batch records, per restaurant and hall day, in a public ETS
  table owned by the driver.

  A batch belongs to the hall day of its last millisecond before the batch's
  `hall_ms` (a batch at exactly midnight belongs to the day that ends there),
  so the tally matches the state the driver samples at each midnight; batches
  at hall time 0 come before day 0's opening sample and are tallied as day -1.

  Amounts are copied from the events, never recomputed:

    * `:purchases` - `market_cleared` fills' `cost`, `stock_purchased.cost`;
    * `:rent_and_wages_paid` - `operating_costs_charged.amount` (rent and the
      staff wages are charged together; the event does not split them);
    * `:fees` - `stall_leased.setup_fee`, `worker_hired.amount`;
    * `:capex` - `recipe_unlocked.cost`, `location_equipped.cost`,
      `location_refitted.cost`, less `equipment_salvaged.amount`;
    * `:grant` - `starter_grant_issued.amount`;
    * `:salvage` - `stock_salvaged.amount`;
    * `:debt_settled` - `distress_cleared.released_debt`;
    * `:unreadable` - a count of `helper_shift_ended` events, whose wages are
      debited from a restaurant the event does not name (key `:any`).
  """
  @behaviour FeudHall.Application.EventStore

  alias FeudHall.Domain.Clock
  alias FeudHall.Infrastructure.InMemoryEventStore, as: Inner

  defstruct [:inner, :table]

  def new(table), do: %__MODULE__{inner: Inner.new(), table: table}

  def fail_next(s, mode), do: %{s | inner: Inner.fail_next(s.inner, mode)}

  @impl true
  def head(s), do: Inner.head(s.inner)
  @impl true
  def stream_versions(s, stream), do: Inner.stream_versions(s.inner, stream)
  @impl true
  def read_from(s, position), do: Inner.read_from(s.inner, position)
  @impl true
  def receipt(s, id), do: Inner.receipt(s.inner, id)
  @impl true
  def held_epoch(s), do: Inner.held_epoch(s.inner)
  @impl true
  def snapshots(s), do: Inner.snapshots(s.inner)
  @impl true
  def projection(s, kind), do: Inner.projection(s.inner, kind)
  @impl true
  def outbox(s), do: Inner.outbox(s.inner)
  @impl true
  def acquire_authority(s, scope, owner), do: rewrap(Inner.acquire_authority(s.inner, scope, owner), s)
  @impl true
  def acquire_authority(s, scope, owner, epoch), do: rewrap(Inner.acquire_authority(s.inner, scope, owner, epoch), s)
  @impl true
  def save_snapshot(s, position, body), do: rewrap(Inner.save_snapshot(s.inner, position, body), s)
  @impl true
  def mark_snapshot_verified(s, id), do: rewrap(Inner.mark_snapshot_verified(s.inner, id), s)
  def prune_snapshots(s, keep \\ 2), do: rewrap(Inner.prune_snapshots(s.inner, keep), s)

  @impl true
  def append(s, request) do
    result = Inner.append(s.inner, request)
    if match?({:ok, _, _}, result) or match?({:error, :unknown_outcome, _}, result), do: tally(s.table, request)
    rewrap(result, s)
  end

  defp rewrap(result, s) do
    result
    |> Tuple.to_list()
    |> Enum.map(fn
      %Inner{} = inner -> %{s | inner: inner}
      other -> other
    end)
    |> List.to_tuple()
  end

  defp tally(table, request) do
    hall_ms = request.context.hall_ms
    day = if hall_ms in [nil, 0], do: -1, else: Clock.day_of(hall_ms - 1)

    for event <- request.events, {rid, component, amount} <- money(event) do
      key = {day, rid, component}
      :ets.update_counter(table, key, amount, {key, 0})
    end

    :ok
  end

  defp money(%{type: :market_cleared, fills: fills}), do: for(f <- fills, do: {f.restaurant_id, :purchases, f.cost})
  defp money(%{type: :stock_purchased} = e), do: [{e.restaurant_id, :purchases, e.cost}]
  defp money(%{type: :operating_costs_charged} = e), do: [{e.restaurant_id, :rent_and_wages_paid, e.amount}]
  defp money(%{type: :stall_leased} = e), do: [{e.restaurant_id, :fees, e.setup_fee}]
  defp money(%{type: :worker_hired} = e), do: [{e.restaurant_id, :fees, e.amount}]

  defp money(%{type: type} = e) when type in [:recipe_unlocked, :location_equipped, :location_refitted],
    do: [{e.restaurant_id, :capex, e.cost}]

  defp money(%{type: :equipment_salvaged} = e), do: [{e.restaurant_id, :capex, -e.amount}]
  defp money(%{type: :starter_grant_issued} = e), do: [{e.restaurant_id, :grant, e.amount}]
  defp money(%{type: :stock_salvaged} = e), do: [{e.restaurant_id, :salvage, e.amount}]
  defp money(%{type: :distress_cleared} = e), do: [{e.restaurant_id, :debt_settled, Map.get(e, :released_debt, 0)}]
  defp money(%{type: :helper_shift_ended}), do: [{:any, :unreadable, 1}]
  defp money(_event), do: []

  @doc "The tally as `%{{day, restaurant_id | :any} => %{component => amount}}`."
  def accounts(table) do
    table
    |> :ets.tab2list()
    |> Enum.reduce(%{}, fn {{day, rid, component}, amount}, acc ->
      Map.update(acc, {day, rid}, %{component => amount}, &Map.put(&1, component, amount))
    end)
  end
end

defmodule FeudHall.CustomerSim.Stats do
  @moduledoc """
  Pure accumulation of per-tick observations and the acceptance verdict.

  An observation is taken after every tick (`observe/3`, a pure function of
  the hall state). Samples (orders waiting, counter activity, stock) belong to
  the hall hour of the instant they were taken; counts (arrivals, admitted,
  mains served, departures) are differences of the hall's cumulative counters
  since the previous observation and belong to the hall hour of the interval
  they cover (its last millisecond before the instant), so an event at exactly
  an hour boundary counts in the earlier hour.

  Day 0 is the warm-up day; days `1..measured_days` are measured. Samples
  after the last measured day are dropped except the midnight ledger (cash,
  revenue, arrears), which closes the last day's profit.

  Profit for a restaurant and day is the change in cash minus the change in
  the arrears of its leases between the two midnights: rent and wages that
  could not be paid are carried as arrears rather than taken from cash, and
  still cost the business. Its components come from the committed events
  (`FeudHall.CustomerSim.Store`) and the ledger's `revenue` account.
  """

  alias FeudHall.Application.Management
  alias FeudHall.Domain.{Clock, Inventory}
  alias FeudHall.Domain.Hall.Progression

  @doc """
  A fresh accumulator. `meta`: `measured_days`, `reference` (stall ID or nil)
  and `owners` (the stall IDs of the reference and every extra owner; the
  reference alone unless given).
  """
  def new(meta) do
    %{
      measured_days: Map.fetch!(meta, :measured_days),
      reference: Map.get(meta, :reference),
      owners: Map.get(meta, :owners, List.wrap(Map.get(meta, :reference))),
      stalls: Map.get(meta, :stalls, %{}),
      day_scales: %{},
      owner_short: %{},
      hours: %{},
      stall_hours: %{},
      hall_hours: %{},
      ledger: %{},
      distressed: %{},
      accounts: %{},
      market_zero: %{},
      reference_short: %{}
    }
  end

  @doc "Sets the event tally (`FeudHall.CustomerSim.Store.accounts/1`)."
  def put_accounts(stats, accounts), do: %{stats | accounts: accounts}

  def put_meta(stats, meta), do: Map.merge(stats, Map.take(meta, [:reference, :owners, :stalls]))

  @doc """
  Sets what the hall recorded about each day's scale, by hall day:
  `equivalents_millis` (the day's own business equivalents, recorded by the
  `day_closed` at its end) and `arrival_scale_millis` (the scale its arrivals
  used, fixed at the midnight that opened it).
  """
  def put_day_scales(stats, day_scales), do: %{stats | day_scales: day_scales}

  @doc "The hall's cumulative counters before anything happened."
  def counters,
    do: %{arrivals: 0, admitted: 0, served: 0, left_on_arrival: %{}, today_left: %{}, next_day_at: Clock.day()}

  @doc "An observation with nothing in it, for `day` and `hour`."
  def blank_observation(day, hour) do
    %{
      at: day * Clock.day() + hour * Clock.hour(),
      day: day,
      hour: hour,
      delta_day: day,
      delta_hour: hour,
      stalls: %{},
      arrivals: 0,
      admitted: 0,
      served: 0,
      left_on_arrival: %{},
      left_after_admission: %{},
      ledger: nil,
      distressed: [],
      market_zero: [],
      reference_short: nil,
      owner_short: %{}
    }
  end

  @doc """
  The observation of `state` and the counters it leaves. `reference` is the
  reference stall ID, or nil; `owners` the stall IDs of every owner stall (the
  reference and the extras). Reads only; never changes the hall.

  Per stall: `waiting`, `cooking` and `handover` from
  `Management.queue_activity/1` (the hall view's own `activity` counts), and
  `open` (the stall is open and the hall is not cleaning). Counts come from
  `state.stats` (simulated arrivals, admissions, arrivals that left with their
  reason, mains served) and `state.demand.today.left`, which also counts
  admitted visits that ended with no course served: the difference is
  `left_after_admission`.
  """
  def observe(state, counters, reference, owners \\ []) do
    at = state.now
    delta_at = max(at - 1, 0)
    stats = state.stats
    activity = Management.queue_activity(state)

    stalls =
      Map.new(activity, fn {sid, a} ->
        {sid, Map.put(a, :open, state.access == :open and state.stalls[sid].mode == :open)}
      end)

    left_on_arrival = stats.left_simulated
    today_left = state.demand.today.left

    # A day closed during this tick: the closed day's tail is in its summary.
    left_total =
      if state.demand.next_day_at != counters.next_day_at do
        closed = List.last(state.demand.summaries).left
        sum_maps(diff(closed, counters.today_left), today_left)
      else
        diff(today_left, counters.today_left)
      end

    arrived_left = diff(left_on_arrival, counters.left_on_arrival)

    observation = %{
      at: at,
      day: Clock.day_of(at),
      hour: hour_of(at),
      delta_day: Clock.day_of(delta_at),
      delta_hour: hour_of(delta_at),
      stalls: stalls,
      arrivals: stats.arrivals_simulated - counters.arrivals,
      admitted: stats.admitted_simulated - counters.admitted,
      served: stats.served_mains - counters.served,
      left_on_arrival: arrived_left,
      left_after_admission: diff(left_total, arrived_left),
      ledger: if(rem(at, Clock.day()) == 0, do: midnight_ledger(state)),
      distressed: for({id, _} <- Enum.sort(state.restaurants), Progression.distressed?(state, id), do: id),
      market_zero: for({p, _} <- Enum.sort(state.catalog.products), Map.get(state.market.stock, p, 0) == 0, do: p),
      reference_short: reference_short(state, reference, stalls),
      owner_short: Map.new(owners, &{&1, reference_short(state, &1, stalls)})
    }

    {observation,
     %{
       arrivals: stats.arrivals_simulated,
       admitted: stats.admitted_simulated,
       served: stats.served_mains,
       left_on_arrival: left_on_arrival,
       today_left: today_left,
       next_day_at: state.demand.next_day_at
     }}
  end

  # Per restaurant: cash, the ledger's revenue account, and its leases' arrears.
  defp midnight_ledger(state) do
    arrears =
      Enum.reduce(state.management.leases, %{}, fn {sid, lease}, acc ->
        Map.update(acc, state.stalls[sid].restaurant, lease.arrears, &(&1 + lease.arrears))
      end)

    Map.new(state.restaurants, fn {id, r} ->
      {id, %{cash: r.ledger.cash, revenue: r.ledger.revenue, arrears: Map.get(arrears, id, 0)}}
    end)
  end

  # An owner stall's menu products whose unreserved, unexpired stock is below
  # one portion's quantity, while the stall is open; nil while closed.
  defp reference_short(_state, nil, _stalls), do: nil

  defp reference_short(state, sid, stalls) do
    if stalls[sid].open do
      restaurant = state.restaurants[state.stalls[sid].restaurant]
      available = Inventory.availability(restaurant.batches, state.now)

      needs =
        for {recipe_id, _price} <- restaurant.menu, line <- state.catalog.recipes[recipe_id].lines, reduce: %{} do
          acc -> Map.update(acc, line.product, line.qty, &max(&1, line.qty))
        end

      for {product, qty} <- Enum.sort(needs), Map.get(available, product, 0) < qty, do: product
    end
  end

  defp hour_of(at), do: div(rem(at, Clock.day()), Clock.hour())

  defp diff(now, before) do
    now
    |> Enum.map(fn {k, v} -> {k, v - Map.get(before, k, 0)} end)
    |> Enum.reject(fn {_k, v} -> v == 0 end)
    |> Map.new()
  end

  defp sum_maps(a, b), do: Map.merge(a, b, fn _k, x, y -> x + y end)

  @doc "Adds one observation."
  def add(stats, obs) do
    stats
    |> add_counts(obs)
    |> add_samples(obs)
    |> add_ledger(obs)
    |> add_distressed(obs)
  end

  defp add_counts(stats, %{delta_day: day} = obs) do
    if day <= stats.measured_days do
      key = {day, obs.delta_hour}
      blank = %{arrivals: 0, admitted: 0, served: 0, left_on_arrival: %{}, left_after_admission: %{}}

      update_in(stats.hours, fn hours ->
        Map.update(hours, key, merge_counts(blank, obs), &merge_counts(&1, obs))
      end)
    else
      stats
    end
  end

  defp merge_counts(acc, obs) do
    %{
      arrivals: acc.arrivals + obs.arrivals,
      admitted: acc.admitted + obs.admitted,
      served: acc.served + obs.served,
      left_on_arrival: sum_maps(acc.left_on_arrival, obs.left_on_arrival),
      left_after_admission: sum_maps(acc.left_after_admission, obs.left_after_admission)
    }
  end

  defp add_samples(stats, %{day: day} = obs) do
    if day <= stats.measured_days do
      key = {day, obs.hour}

      stall_hours =
        Enum.reduce(obs.stalls, stats.stall_hours, fn {sid, s}, acc ->
          sample = %{
            samples: 1,
            waiting: s.waiting,
            busy: bit(s.cooking > 0 or s.handover),
            cooking: bit(s.cooking > 0),
            handover: bit(s.handover),
            open: bit(s.open)
          }

          Map.update(acc, {day, obs.hour, sid}, sample, &sum_maps(&1, sample))
        end)

      hall =
        if map_size(obs.stalls) > 0 do
          total = obs.stalls |> Map.values() |> Enum.map(& &1.waiting) |> Enum.sum()
          %{samples: 1, waiting_per_stall: total / map_size(obs.stalls)}
        else
          %{samples: 1, waiting_per_stall: 0.0}
        end

      zero = Map.new(obs.market_zero, &{&1, 1})

      short =
        case obs.reference_short do
          nil -> %{open: 0, short: 0, products: %{}}
          products -> %{open: 1, short: bit(products != []), products: Map.new(products, &{&1, 1})}
        end

      owner_short =
        Enum.reduce(obs.owner_short, stats.owner_short, fn
          {_sid, nil}, acc -> acc
          {sid, products}, acc -> Map.update(acc, sid, bit(products != []), &(&1 + bit(products != [])))
        end)

      %{
        stats
        | stall_hours: stall_hours,
          owner_short: owner_short,
          hall_hours: Map.update(stats.hall_hours, key, hall, &sum_maps(&1, hall)),
          market_zero: Map.update(stats.market_zero, day, zero, &sum_maps(&1, zero)),
          reference_short:
            Map.update(stats.reference_short, day, short, fn acc ->
              %{
                open: acc.open + short.open,
                short: acc.short + short.short,
                products: sum_maps(acc.products, short.products)
              }
            end)
      }
    else
      stats
    end
  end

  defp add_ledger(stats, %{ledger: nil}), do: stats
  defp add_ledger(stats, %{ledger: ledger, day: day}), do: put_in(stats.ledger[day], ledger)

  defp add_distressed(stats, %{distressed: []}), do: stats

  defp add_distressed(stats, %{distressed: ids, day: day}) do
    if day <= stats.measured_days,
      do:
        update_in(
          stats.distressed,
          &Map.update(&1, day, MapSet.new(ids), fn set -> MapSet.union(set, MapSet.new(ids)) end)
        ),
      else: stats
  end

  defp bit(true), do: 1
  defp bit(false), do: 0

  @doc "Time averages for one stall in one hall hour of one day."
  def stall_hour(stats, day, hour, sid), do: shares(Map.get(stats.stall_hours, {day, hour, sid}))

  defp shares(nil), do: %{samples: 0, waiting: 0.0, busy: 0.0, cooking: 0.0, handover: 0.0, open: 0.0}

  defp shares(%{samples: n} = s) do
    %{
      samples: n,
      waiting: round4(s.waiting / n),
      busy: round4(s.busy / n),
      cooking: round4(s.cooking / n),
      handover: round4(s.handover / n),
      open: round4(s.open / n)
    }
  end

  defp measured(stats), do: if(stats.measured_days >= 1, do: Enum.to_list(1..stats.measured_days), else: [])

  # Unrounded time averages over the measured days and `hours`, for one stall.
  defp window(stats, hours, sid) do
    acc =
      for day <- measured(stats),
          hour <- hours,
          s = Map.get(stats.stall_hours, {day, hour, sid}),
          s != nil,
          reduce: %{samples: 0, waiting: 0, busy: 0} do
        acc -> %{samples: acc.samples + s.samples, waiting: acc.waiting + s.waiting, busy: acc.busy + s.busy}
      end

    if acc.samples == 0,
      do: %{waiting: 0.0, busy: 0.0},
      else: %{waiting: acc.waiting / acc.samples, busy: acc.busy / acc.samples}
  end

  defp hall_window(stats, hours) do
    {n, sum} =
      for day <- measured(stats),
          hour <- hours,
          h = Map.get(stats.hall_hours, {day, hour}),
          h != nil,
          reduce: {0, 0.0} do
        {n, sum} -> {n + h.samples, sum + h.waiting_per_stall}
      end

    if n == 0, do: 0.0, else: sum / n
  end

  defp totals(stats, days) do
    blank = %{arrivals: 0, admitted: 0, served: 0, left_on_arrival: %{}, left_after_admission: %{}}

    for day <- days, hour <- 0..23, h = Map.get(stats.hours, {day, hour}), h != nil, reduce: blank do
      acc -> merge_counts(acc, h)
    end
  end

  @doc "Mains served during hall day `day` (0 is the warm-up day)."
  def day_served(stats, day), do: totals(stats, [day]).served

  @doc """
  The acceptance checks for run `:a` or `:b`, in the spec's bounds (see the
  Project 4 acceptance section of the livelier-hall design). Values cover the
  measured days, except the run-B first-day check, which is hall day 0.
  """
  def verdict(run, stats) when run in [:a, :b] do
    total = totals(stats, measured(stats))
    served_share = ratio(total.served, total.arrivals)

    specific =
      case run do
        :a -> run_a(stats)
        :b -> run_b(stats, total)
      end

    specific ++
      [
        %{
          check: "served share (mains served / arrivals; no bound here)",
          value: round4(served_share),
          low: nil,
          high: nil,
          pass: true
        }
      ]
  end

  defp run_a(stats) do
    ref = stats.reference
    short = for day <- measured(stats), d = stats.reference_short[day], d != nil, reduce: 0, do: (n -> n + d.short)

    [
      check("A ref waiting 12:00-13:00", window(stats, [12], ref).waiting, 2.5, 4.5),
      check("A ref waiting 19:00-20:00", window(stats, [19], ref).waiting, 2.5, 4.5),
      check("A ref busy 12:00-13:00", window(stats, [12], ref).busy, 0.85, nil),
      check("A ref busy 19:00-20:00", window(stats, [19], ref).busy, 0.85, nil),
      check("A ref waiting 10:00-11:00", window(stats, [10], ref).waiting, 0.5, 2),
      check("A ref waiting 14:00-17:00", window(stats, [14, 15, 16], ref).waiting, 0.5, 2),
      check("A hall waiting per stall 00:00-03:00", hall_window(stats, [0, 1, 2]), nil, 0.3),
      check("A ref open instants short of an ingredient", short, nil, 0),
      open_check(stats, ref),
      owner_mean(stats, 12),
      owner_mean(stats, 19)
    ]
  end

  # Reported, never judged: the mean over the owner stalls (the reference and
  # any extras) of each stall's time-averaged orders waiting in a rush hour.
  defp owner_mean(stats, hour) do
    values = Enum.map(stats.owners, &window(stats, [hour], &1).waiting)
    mean = if values == [], do: 0.0, else: Enum.sum(values) / length(values)
    check("A owner stalls mean waiting #{hour}:00-#{hour + 1}:00", mean, nil, nil)
  end

  @checked_hours [10, 12, 14, 15, 16, 19]

  @doc "The name of the run-A row that fails a run's exit status: a checked hour with the reference closed."
  def open_check_name, do: "A ref open during checked hours"

  # The share of samples in the checked hours in which the reference stall was
  # open, with each hour's own share, so a closed target hour shows up by name.
  defp open_check(stats, ref) do
    per_hour =
      Map.new(@checked_hours, fn hour ->
        acc =
          for day <- measured(stats), s = Map.get(stats.stall_hours, {day, hour, ref}), s != nil, reduce: {0, 0} do
            {n, open} -> {n + s.samples, open + s.open}
          end

        {hour, acc}
      end)

    {n, open} = per_hour |> Map.values() |> Enum.reduce({0, 0}, fn {n, o}, {tn, to} -> {tn + n, to + o} end)

    open_check_name()
    |> check(ratio(open, n), 0.99, nil)
    |> Map.put(:hours, Map.new(per_hour, fn {hour, {n, o}} -> {hour, round4(ratio(o, n))} end))
  end

  defp run_b(stats, total) do
    left = total.left_on_arrival |> Map.values() |> Enum.sum()
    share = ratio(Map.get(total.left_on_arrival, :nothing_available, 0), left)

    [
      check("B nothing_available share of left on arrival", share, nil, 0.25),
      check("B mains served on day 0", day_served(stats, 0), 1, nil)
    ]
  end

  defp check(name, value, low, high) do
    pass = (low == nil or value >= low) and (high == nil or value <= high)
    %{check: name, value: round4(value), low: low, high: high, pass: pass}
  end

  defp ratio(_n, 0), do: 0.0
  defp ratio(n, d), do: n / d

  defp round4(v) when is_integer(v), do: v
  defp round4(v) when is_float(v), do: Float.round(v, 4)

  @doc "Every number the driver prints, as plain data (also the JSON body)."
  def summary(stats) do
    stall_ids = stats.stalls |> Map.keys() |> Enum.sort()

    hours =
      for day <- measured(stats), hour <- 0..23 do
        counts = totals_for(stats, day, hour)
        hall = Map.get(stats.hall_hours, {day, hour})

        Map.merge(counts, %{
          day: day,
          hour: hour,
          hall_waiting_per_stall: if(hall, do: round4(hall.waiting_per_stall / hall.samples), else: 0.0),
          stalls: Map.new(stall_ids, &{&1, stall_hour(stats, day, hour, &1)})
        })
      end

    days =
      for day <- 0..stats.measured_days do
        counts = totals(stats, [day])
        short = Map.get(stats.reference_short, day, %{open: 0, short: 0, products: %{}})

        scale = Map.get(stats.day_scales, day, %{})

        Map.merge(counts, %{
          day: day,
          warm_up: day == 0,
          equivalents_millis: Map.get(scale, :equivalents_millis),
          arrival_scale_millis: Map.get(scale, :arrival_scale_millis),
          served_share: round4(ratio(counts.served, counts.arrivals)),
          profit: profit(stats, day),
          market_zero_ticks: Map.get(stats.market_zero, day, %{}),
          reference_open_samples: short.open,
          reference_short_samples: short.short,
          reference_short_products: short.products
        })
      end

    %{hours: hours, days: days}
  end

  @doc """
  For every stall, over the measured days, what the verdict reads for the
  reference stall: time-averaged orders waiting and counter-busy share in the
  checked hours, the share of the checked hours it was open, and for an owner
  stall the open instants it was short of an ingredient (nil for a
  computer-run stall, which is not sampled for it).
  """
  def checked_hours(stats) do
    for sid <- stats.stalls |> Map.keys() |> Enum.sort() do
      meta = stats.stalls[sid]
      rush = fn hour -> window(stats, [hour], sid) end

      {n, open} =
        for day <- measured(stats),
            hour <- @checked_hours,
            s = Map.get(stats.stall_hours, {day, hour, sid}),
            s != nil,
            reduce: {0, 0} do
          {n, open} -> {n + s.samples, open + s.open}
        end

      %{
        stall: sid,
        restaurant: meta.restaurant,
        npc: meta.npc,
        cuisine: meta.cuisine,
        waiting_12: round4(rush.(12).waiting),
        waiting_19: round4(rush.(19).waiting),
        busy_12: round4(rush.(12).busy),
        busy_19: round4(rush.(19).busy),
        waiting_10: round4(rush.(10).waiting),
        waiting_14_17: round4(window(stats, [14, 15, 16], sid).waiting),
        open_share: round4(ratio(open, n)),
        short: if(sid in stats.owners, do: Map.get(stats.owner_short, sid, 0))
      }
    end
  end

  @doc """
  For each rush hour (12:00 and 19:00), over the measured days: arrivals in
  the hour per day, the time-averaged number of stalls open during it, and
  the first divided by the second.
  """
  def rush_hours(stats) do
    days = measured(stats)

    for hour <- [12, 19] do
      arrivals = Enum.sum(for day <- days, do: totals_for(stats, day, hour).arrivals)

      open =
        for day <- days, {{^day, ^hour, _sid}, s} <- stats.stall_hours, reduce: 0.0 do
          acc -> acc + s.open / s.samples
        end

      %{
        hour: hour,
        arrivals_per_day: round4(ratio(arrivals, length(days)) / 1),
        open_stalls: round4(ratio(open, length(days)) / 1),
        arrivals_per_open_stall: if(open > 0, do: round4(arrivals / open), else: 0.0)
      }
    end
  end

  defp totals_for(stats, day, hour),
    do:
      Map.get(stats.hours, {day, hour}, %{
        arrivals: 0,
        admitted: 0,
        served: 0,
        left_on_arrival: %{},
        left_after_admission: %{}
      })

  @doc """
  Per restaurant present at both of the day's midnights: `profit` (cash
  change minus arrears change), `cash_change`, `arrears_change`,
  `distressed` (at any sampled instant of the day), and the components:
  `revenue` (ledger revenue change), `purchases`, `rent_and_wages_charged`
  (paid plus newly in arrears; rent and wages are not recorded separately),
  `other` (grant and salvage less fees, capital spending and settled debt),
  `unreadable` (events whose amounts cannot be assigned) and `remainder`
  (profit minus revenue, purchases, rent and wages, and other).
  """
  def profit(stats, day) do
    with %{} = start <- stats.ledger[day], %{} = finish <- stats.ledger[day + 1] do
      distressed = Map.get(stats.distressed, day, MapSet.new())
      unreadable_any = get_in(stats.accounts, [{day, :any}, :unreadable]) || 0

      for {id, f} <- finish, s = start[id], s != nil, into: %{} do
        a = Map.get(stats.accounts, {day, id}, %{})
        at = &Map.get(a, &1, 0)
        cash_change = f.cash - s.cash
        arrears_change = f.arrears - s.arrears
        profit = cash_change - arrears_change
        revenue = f.revenue - s.revenue
        charged = at.(:rent_and_wages_paid) + arrears_change
        other = at.(:grant) + at.(:salvage) - at.(:fees) - at.(:capex) - at.(:debt_settled)

        {id,
         %{
           profit: profit,
           cash_change: cash_change,
           arrears_change: arrears_change,
           distressed: MapSet.member?(distressed, id),
           revenue: revenue,
           purchases: at.(:purchases),
           rent_and_wages_charged: charged,
           other: other,
           unreadable: at.(:unreadable) + unreadable_any,
           remainder: profit - (revenue - at.(:purchases) - charged + other)
         }}
      end
    else
      _ -> %{}
    end
  end

  @doc "Day profits whose components do not add up although every component was read."
  def inconsistencies(stats) do
    for day <- 0..stats.measured_days,
        {id, p} <- Enum.sort(profit(stats, day)),
        p.unreadable == 0 and p.remainder != 0,
        do: {:profit_unexplained, %{day: day, restaurant: id, remainder: p.remainder}}
  end

  @doc """
  Restaurants that make a profit comparison unreliable: distressed at any
  sampled instant of a measured day, or with lease arrears at the last midnight.
  """
  def warnings(stats) do
    distressed =
      for day <- measured(stats), id <- Enum.sort(Map.get(stats.distressed, day, MapSet.new())), do: {id, day}

    by_restaurant = Enum.group_by(distressed, &elem(&1, 0), &elem(&1, 1))
    final = Map.get(stats.ledger, stats.measured_days + 1, %{})
    in_arrears = for {id, %{arrears: a}} <- final, a > 0, into: %{}, do: {id, a}

    (Map.keys(by_restaurant) ++ Map.keys(in_arrears))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(
      &%{restaurant: &1, distressed_days: Map.get(by_restaurant, &1, []), arrears_at_end: Map.get(in_arrears, &1, 0)}
    )
  end
end

defmodule FeudHall.CustomerSim.Hall do
  @moduledoc """
  Starts a managed launch hall authority in memory and drives it tick by tick.

  Run A adds the reference owner at the start of its schedule (`hours`,
  default 10:00-20:00) on the warm-up day, selling the starter main of
  `reference_cuisine/2` (the median-priced unused starter unless `cuisine`
  names another): a registered
  principal admitted by the admin the way a seeded owner is, who then issues
  ordinary owner commands through `HallAuthority.management_execute/3`.
  `extra_stalls` adds that many more owners at the same instant, each set up
  by the same commands with the same hours and restock rule, on the first free
  standard spot of an open room and on its own cuisine (`extra_cuisines/3`).
  `--via retune` applies the tuning with `retune_rules` at 12:00 of the
  warm-up day, so it is in force from the first measured midnight.
  """

  alias FeudHall.CustomerSim.{Clock, Sink, Stats, Store}
  alias FeudHall.Domain.Identity
  alias FeudHall.Domain.Clock, as: HallClock
  alias FeudHall.Domain.Content.{LaunchCatalog, Tuning}
  alias FeudHall.Domain.Hall.{Management, Rooms}
  alias FeudHall.Infrastructure.HallAuthority

  @scope "customer-sim"
  @reference %{device: "reference-owner", restaurant: "reference", name: "Reference", seed: "sim:seed-reference"}
  @max_extra_stalls 8

  @doc "The most extra owner stalls a run may ask for."
  def max_extra_stalls, do: @max_extra_stalls

  def ticks_per_hour, do: div(HallClock.service_ms(HallClock.hour()), 1_000)
  def ticks_per_day, do: div(HallClock.service_ms(HallClock.day()), 1_000)

  @doc """
  Runs the hall: one warm-up day and `days` measured days, one tick per
  service second. Options: `run` (`:a | :b`), `tuning`, `via` (`:init |
  :retune`), `days`, `seed`, and optionally `hours`, `cuisine` (the reference
  owner's cuisine, overriding the default), `extra_stalls` (run A only, 0 to
  #{@max_extra_stalls}), `observer` (called as
  `observer.(tick, authority)` after each tick's commands) and `progress`
  (called with `{day, stats}` at each midnight).

  Returns `{:ok, result}` with the authority still running (the caller stops
  it), or `{:error, reason}` when a command it issued was refused or a tick
  failed.
  """
  def run(opts) do
    clock = :atomics.new(1, [])
    table = :ets.new(:customer_sim_diagnostics, [:public, :bag])
    money = :ets.new(:customer_sim_money, [:public, :set])

    {:ok, authority} =
      HallAuthority.start_link(
        scope: @scope,
        owner: "customer-sim",
        store_mod: Store,
        store: Store.new(money),
        clock: {Clock, clock},
        tick_ms: :manual,
        diagnostics: {Sink, table},
        # Snapshots change no gameplay; the run never restarts, so skip them.
        snapshot_every_events: 1_000_000_000_000,
        snapshot_every_service_ms: 1_000_000_000_000
      )

    try do
      {:ok, drive(authority, clock, table, money, opts)}
    catch
      {:refused, id, result} ->
        GenServer.stop(authority)
        {:error, {:refused, id, result}}

      {:tick_failed, tick, reason} ->
        GenServer.stop(authority)
        {:error, {:tick_failed, tick, reason}}
    end
  end

  defp drive(authority, clock, table, money, opts) do
    catalog = if opts.via == :init, do: Tuning.put(LaunchCatalog.catalog(), opts.tuning), else: LaunchCatalog.catalog()
    init = %{hall_id: @scope, catalog: catalog, managed: true, seed: opts.seed}
    admin(authority, "sim:init", {:initialize_hall, init})
    admin(authority, "sim:visitor-play", {:enable_visitor_play, %{}})

    extra = Map.get(opts, :extra_stalls) || 0

    if extra not in 0..@max_extra_stalls or (extra > 0 and opts.run != :a),
      do: throw({:refused, "extra-stalls", {:bad_count, extra}})

    stats = Stats.new(%{measured_days: opts.days})
    first = hall(authority)
    initial_scale = first.demand.supply_scale_millis
    {obs, counters} = Stats.observe(first, Stats.counters(), nil)
    stats = Stats.add(stats, obs)
    last = (opts.days + 1) * ticks_per_day()
    {start, _finish} = hours = Map.get(opts, :hours, default_hours())

    {stats, _counters, owners} =
      Enum.reduce(1..last, {stats, counters, []}, fn tick, {stats, counters, owners} ->
        :atomics.put(clock, 1, tick * 1_000)

        case HallAuthority.tick(authority) do
          :ok -> :ok
          {:error, reason} -> throw({:tick_failed, tick, reason})
        end

        owners =
          if opts.run == :a and tick == start * ticks_per_hour(),
            do: open_owners(authority, hours, opts[:cuisine], extra),
            else: owners

        if opts.via == :retune and tick == 12 * ticks_per_hour() do
          admin(authority, "sim:retune", {:retune_rules, %{tuning: opts.tuning}})
        end

        if observer = opts[:observer], do: observer.(tick, authority)
        state = hall(authority)
        {obs, counters} = Stats.observe(state, counters, reference_stall(owners), Enum.map(owners, & &1.stall_id))
        stats = Stats.add(stats, obs)

        if rem(tick, ticks_per_day()) == 0 do
          stats = Stats.put_meta(stats, owner_meta(owners, state))
          if progress = opts[:progress], do: progress.({div(tick, ticks_per_day()), stats})
          {stats, counters, owners}
        else
          {stats, counters, owners}
        end
      end)

    stats =
      stats
      |> Stats.put_meta(owner_meta(owners, hall(authority)))
      |> Stats.put_accounts(Store.accounts(money))
      |> Stats.put_day_scales(day_scales(authority, initial_scale))

    reference = List.first(owners)

    served = Enum.sum(for day <- 0..opts.days, do: Stats.day_served(stats, day))

    problems =
      for({name, fields} <- Sink.records(table), do: {name, Map.take(fields, [:command_id, :reason])}) ++
        if(served == 0, do: [{:never_served, %{}}], else: []) ++ Stats.inconsistencies(stats)

    open = Enum.find(Stats.verdict(opts.run, stats), &(&1.check == Stats.open_check_name()))

    problems =
      if open && not open.pass, do: problems ++ [{:reference_closed_in_checked_hours, open.hours}], else: problems

    %{
      stats: stats,
      authority: authority,
      reference: reference,
      owners: owners,
      tuning: opts.tuning,
      hours: hours,
      problems: problems
    }
  end

  defp hall(authority), do: HallAuthority.state(authority).hall

  defp reference_stall([reference | _]), do: reference.stall_id
  defp reference_stall([]), do: nil

  defp owner_meta(owners, state),
    do: %{reference: reference_stall(owners), owners: Enum.map(owners, & &1.stall_id), stalls: stall_meta(state)}

  # What the hall recorded about each day's scale, read from the committed
  # `day_closed` events: the one at the end of day D carries D's business
  # equivalents and the scale for day D + 1's arrivals. Day 0 runs at the scale
  # the hall started with (the floor).
  defp day_scales(authority, initial_scale) do
    {store_mod, store} = HallAuthority.store(authority)
    {:ok, batches} = store_mod.read_from(store, 0)
    closed = for batch <- batches, %{type: :day_closed} = event <- batch.events, do: event

    Enum.reduce(closed, %{0 => %{arrival_scale_millis: initial_scale}}, fn event, acc ->
      acc
      |> Map.update(event.day, %{equivalents_millis: event.equivalents_millis}, fn day ->
        Map.put(day, :equivalents_millis, event.equivalents_millis)
      end)
      |> Map.put(event.day + 1, %{arrival_scale_millis: event.scale_millis})
    end)
  end

  defp stall_meta(state) do
    Map.new(state.stalls, fn {sid, stall} ->
      restaurant = state.restaurants[stall.restaurant]
      {sid, %{restaurant: restaurant.id, npc: restaurant.owner_kind == :npc, cuisine: restaurant.cuisine}}
    end)
  end

  @doc """
  The reference schedule unless `--hours` says otherwise: ten hours, the
  longest the three starter staff work before their protective break (after
  ten working hours), so the stall is open through both rush windows.
  """
  def default_hours, do: {10, 20}

  # The reference owner first, then the extra owners; cuisines are settled
  # before any command so a shortage refuses the run before it changes the hall.
  defp open_owners(authority, hours, override, extra) do
    state = hall(authority)
    cuisine = reference_cuisine(state, override)
    extras = extra_cuisines(state, cuisine, extra)
    reference = open_owner(authority, @reference, hours, cuisine, &reference_spot/1)

    more =
      for {extra_cuisine, n} <- Enum.with_index(extras, 1) do
        who = %{device: "extra-owner-#{n}", restaurant: "extra-#{n}", name: "Extra #{n}", seed: "sim:seed-extra-#{n}"}
        open_owner(authority, who, hours, extra_cuisine, &extra_spot(&1, n, extra))
      end

    [reference | more]
  end

  # An owner: registers, is admitted as a seeded owner is, leases a free
  # standard spot (the reference the first in room 1 by spot ID, an extra owner
  # the first in any open room), creates a default restaurant (its starter main
  # at the suggested price, three starter staff), sets the staff schedule to
  # `hours`, trades unattended with no cash floor (the restock policy only runs
  # for an unattended open stall), sets a restock policy for every product of
  # the starter main, and opens.
  defp open_owner(authority, who, {start, finish}, cuisine, spot) do
    state = hall(authority)
    starter = starter_mains(state.catalog)[cuisine]
    sid = spot.(state)
    client = &client(authority, who.device, &1, &2)

    client.("register", {:bootstrap_guest, %{name: "#{who.name} Owner"}})
    principal = Identity.principal_for_device(Identity.get(HallAuthority.state(authority).control), who.device)
    admin(authority, who.seed, {:seed_owner, %{principal: principal, reviewer?: false}})
    client.("reserve", {:reserve_stall, %{stall_id: sid}})

    client.(
      "create",
      {:create_restaurant,
       %{stall_id: sid, restaurant_id: who.restaurant, cuisine: cuisine, name: "#{who.name} Kitchen"}}
    )

    client.("staff", {:set_staff_schedule, %{stall_id: sid, start_hour: start, end_hour: finish}})
    client.("unattended", {:set_unattended_policy, %{stall_id: sid, enabled: true, cash_floor: 0}})
    policies = restock_policies(hall(authority), starter)

    for policy <- policies do
      client.("restock:#{policy.product}", {:set_restock_policy, Map.put(policy, :restaurant_id, who.restaurant)})
    end

    client.("open", {:open_stall, %{stall_id: sid}})

    %{
      stall_id: sid,
      restaurant_id: who.restaurant,
      cuisine: cuisine,
      recipe: starter.id,
      price: starter.suggested_price,
      restock: policies
    }
  end

  @doc "Each cuisine's starter main, by cuisine ID."
  def starter_mains(catalog) do
    for {_id, %{starter: true, kind: :main} = recipe} <- catalog.recipes, into: %{}, do: {recipe.cuisine, recipe}
  end

  @doc """
  The default reference cuisine: among the cuisines no restaurant has yet, the
  one whose starter main has the median suggested price, so the reference
  stall stands for a typical new owner rather than a dear or cheap one. With
  an even count the median is the lower of the two middle prices; of several
  cuisines at that price the first by cuisine ID is taken.
  """
  def reference_cuisine(state) do
    unused = unused_starters(state)
    prices = unused |> Enum.map(fn {_cuisine, recipe} -> recipe.suggested_price end) |> Enum.sort()
    median = Enum.at(prices, div(length(prices) - 1, 2))

    unused
    |> Enum.filter(fn {_cuisine, recipe} -> recipe.suggested_price == median end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.min()
  end

  @doc """
  The reference cuisine: `override` when given, which must have a starter main
  and be taken by no restaurant (otherwise the run is refused), else the
  default of `reference_cuisine/1`.
  """
  def reference_cuisine(state, nil), do: reference_cuisine(state)

  def reference_cuisine(state, override) do
    cond do
      not Map.has_key?(starter_mains(state.catalog), override) ->
        throw({:refused, "reference-cuisine", {:unknown_cuisine, override}})

      not Map.has_key?(unused_starters(state), override) ->
        throw({:refused, "reference-cuisine", {:cuisine_taken, override}})

      true ->
        override
    end
  end

  @doc """
  The cuisines of `count` extra owners: the unused cuisines other than the
  reference's, nearest first by the distance of the starter main's suggested
  price from the median unused price (the price `reference_cuisine/1` picks),
  then the lower price, then the cuisine ID. Refuses the run when fewer than
  `count` are left.
  """
  def extra_cuisines(_state, _reference, 0), do: []

  def extra_cuisines(state, reference, count) do
    unused = unused_starters(state)
    median = unused[reference_cuisine(state)].suggested_price

    ordered =
      unused
      |> Map.delete(reference)
      |> Enum.sort_by(fn {cuisine, recipe} ->
        {abs(recipe.suggested_price - median), recipe.suggested_price, cuisine}
      end)
      |> Enum.map(&elem(&1, 0))

    if length(ordered) < count,
      do: throw({:refused, "extra-stalls", {:no_unused_cuisine, %{wanted: count, available: length(ordered)}}})

    Enum.take(ordered, count)
  end

  defp unused_starters(state) do
    taken = MapSet.new(Map.values(state.restaurants), & &1.cuisine)
    Map.reject(starter_mains(state.catalog), fn {cuisine, _recipe} -> MapSet.member?(taken, cuisine) end)
  end

  defp reference_spot(state) do
    summary = Rooms.summary(state)

    state.catalog.layout
    |> Enum.sort_by(& &1.slot_id)
    |> Enum.find_value(fn spot ->
      quote = spot.tier == :standard and Management.lease_quote(state, spot.slot_id, summary)
      if quote && quote.room == 1, do: spot.slot_id
    end) || throw({:refused, "reference-spot", :no_standard_spot_in_room_1})
  end

  # The first free standard spot (by spot ID) the hall will quote a lease for, which it
  # does only in an open room.
  defp extra_spot(state, n, wanted) do
    summary = Rooms.summary(state)

    state.catalog.layout
    |> Enum.sort_by(& &1.slot_id)
    |> Enum.find_value(fn spot ->
      spot.tier == :standard and Management.lease_quote(state, spot.slot_id, summary) != nil and spot.slot_id
    end) ||
      throw({:refused, "extra-stalls", {:no_standard_spot_in_an_open_room, %{wanted: wanted, placed: n - 1}}})
  end

  # Generous enough not to run out while the market can supply: the stock
  # target is four hours of the kitchen's maximum output (the policy tops up
  # every hall hour), the price limit is the market's price ceiling (so the
  # published price never stops a purchase), and the daily budget buys a full
  # twelve-hour day of maximum output at that ceiling.
  defp restock_policies(state, recipe) do
    kitchen = state.catalog.rules.kitchen
    hour = HallClock.hour()

    per_hour =
      min(
        div(kitchen.prep_stations * hour, max(recipe.prep_ms, 1)),
        div(kitchen.finish_stations * hour, max(recipe.finish_ms, 1))
      )

    for line <- Enum.sort_by(recipe.lines, & &1.product) do
      limit = ceiling_price(state.catalog, line.product)

      %{
        product: line.product,
        target: line.qty * per_hour * 4,
        max_price_per_kunit: limit,
        daily_budget: div(line.qty * per_hour * 12 * limit + 999, 1_000)
      }
    end
  end

  # Market.price clamps to this ceiling, so a limit at it is never below the published price.
  defp ceiling_price(catalog, product) do
    rules = catalog.rules.market
    base = catalog.products[product].base_price_per_kunit
    floor = max(1, div(base * rules.price_floor_permille, 1000))
    max(floor, div(base * rules.price_ceiling_permille, 1000))
  end

  defp admin(authority, id, command) do
    envelope = %{command_id: id, actor: {:system, :admin}, command: command}
    accepted!(id, HallAuthority.execute(authority, envelope))
  end

  defp client(authority, device, suffix, command) do
    id = "#{device}:#{suffix}"
    accepted!(id, HallAuthority.management_execute(authority, device, %{command_id: id, command: command}))
  end

  defp accepted!(_id, {:accepted, %{outcome: :accepted}} = result), do: result
  defp accepted!(id, result), do: throw({:refused, id, result})
end

defmodule FeudHall.CustomerSim.CLI do
  @moduledoc false
  alias FeudHall.CustomerSim.{Hall, Stats}
  alias FeudHall.Domain.Content.{LaunchCatalog, Tuning}

  @max_days 14
  @runs %{"a" => :a, "b" => :b}
  @vias %{"init" => :init, "retune" => :retune}
  @usage "usage: mix run --no-start scripts/customer_sim.exs -- --run a|b --tuning current|chosen|PATH " <>
           "--days N --seed S [--via init|retune] [--hours START-END] [--cuisine ID] [--extra-stalls N] " <>
           "[--set KEY=VALUE ...] [--json PATH]"

  def main(argv) do
    started = System.monotonic_time(:millisecond)

    with {:ok, args} <- parse(argv),
         {:ok, tuning} <- tuning(args.tuning, args.set) do
      sets = if args.set == [], do: "", else: " with #{Enum.join(args.set, " ")}"

      IO.puts(
        "Run #{args.run}, tuning #{args.tuning}#{sets} (version #{tuning.version}), via #{args.via}, seed #{args.seed}, " <>
          "1 warm-up day + #{args.days} measured, reference hours #{hours_label(args.hours)}, " <>
          "reference cuisine #{args.cuisine || "by median starter price"}, extra owner stalls #{args.extra_stalls}"
      )

      opts = %{
        run: args.run,
        tuning: tuning,
        via: args.via,
        days: args.days,
        seed: args.seed,
        hours: args.hours,
        cuisine: args.cuisine,
        extra_stalls: args.extra_stalls,
        progress: &progress(&1, args.days)
      }

      case Hall.run(opts) do
        {:ok, result} ->
          GenServer.stop(result.authority)
          print(result, args)
          if args.json, do: File.write!(args.json, json(result, args))
          IO.puts("Wall clock: #{System.monotonic_time(:millisecond) - started} ms")

          if result.problems != [] do
            IO.puts(:stderr, "Run is not trustworthy: #{inspect(result.problems)}")
            System.halt(1)
          end

        {:error, reason} ->
          IO.puts(:stderr, "Run failed: #{failure(reason)}")
          System.halt(1)
      end
    else
      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  defp failure({:refused, "extra-stalls", {:no_unused_cuisine, %{wanted: wanted, available: available}}}),
    do: "the hall cannot place #{wanted} extra stalls: only #{available} unused cuisines are left"

  defp failure({:refused, "extra-stalls", {:no_standard_spot_in_an_open_room, %{wanted: wanted, placed: placed}}}),
    do: "the hall cannot place #{wanted} extra stalls: no free standard spot in an open room after #{placed}"

  defp failure(reason), do: inspect(reason)

  def parse(argv) do
    argv = Enum.drop_while(argv, &(&1 == "--"))

    strict = [
      run: :string,
      tuning: :string,
      days: :integer,
      seed: :integer,
      via: :string,
      hours: :string,
      cuisine: :string,
      extra_stalls: :integer,
      set: :keep,
      json: :string
    ]

    case OptionParser.parse(argv, strict: strict) do
      {opts, [], []} ->
        args = %{
          run: opts[:run],
          tuning: Keyword.get(opts, :tuning, "current"),
          days: Keyword.get(opts, :days, 3),
          seed: Keyword.get(opts, :seed, LaunchCatalog.catalog().rules.seed),
          via: Keyword.get(opts, :via, "init"),
          set: Keyword.get_values(opts, :set),
          json: opts[:json],
          hours: parse_hours(Keyword.get(opts, :hours)),
          cuisine: opts[:cuisine],
          extra_stalls: Keyword.get(opts, :extra_stalls, 0)
        }

        cond do
          args.run not in ["a", "b"] ->
            {:error, "--run must be a or b\n" <> @usage}

          args.via not in ["init", "retune"] ->
            {:error, "--via must be init or retune\n" <> @usage}

          args.days < 0 or args.days > @max_days ->
            {:error, "--days must be 0..#{@max_days}\n" <> @usage}

          args.seed < 0 ->
            {:error, "--seed must be non-negative\n" <> @usage}

          args.hours == :error ->
            {:error, "--hours must be START-END, two hall hours in 0..23 that differ\n" <> @usage}

          args.cuisine != nil and args.run != "a" ->
            {:error, "--cuisine applies to run a only\n" <> @usage}

          args.cuisine != nil and args.cuisine not in cuisines() ->
            {:error, "--cuisine must be one of #{Enum.join(cuisines(), ", ")}\n" <> @usage}

          args.extra_stalls not in 0..Hall.max_extra_stalls() ->
            {:error, "--extra-stalls must be 0..#{Hall.max_extra_stalls()}\n" <> @usage}

          args.extra_stalls > 0 and args.run != "a" ->
            {:error, "--extra-stalls applies to run a only\n" <> @usage}

          true ->
            {:ok, %{args | run: @runs[args.run], via: @vias[args.via]}}
        end

      {_, rest, invalid} ->
        {:error, "unrecognised arguments #{inspect(rest ++ Enum.map(invalid, &elem(&1, 0)))}\n" <> @usage}
    end
  end

  # The launch catalog's cuisines that have a starter main. Whether one is already taken is known only in the run.
  defp cuisines, do: LaunchCatalog.catalog() |> Hall.starter_mains() |> Map.keys() |> Enum.sort()

  defp parse_hours(nil), do: Hall.default_hours()

  defp parse_hours(text) do
    with [a, b] <- String.split(text, "-"),
         {start, ""} <- Integer.parse(a),
         {finish, ""} <- Integer.parse(b),
         true <- start in 0..23 and finish in 0..23 and start != finish do
      {start, finish}
    else
      _ -> :error
    end
  end

  def hours_label({start, finish}), do: "#{pad(start)}:00-#{pad(finish)}:00"

  @doc "The tuning named by `source` with every `KEY=VALUE` override applied, validated against the launch catalog."
  def tuning(source, sets) do
    with {:ok, base} <- base_tuning(source),
         {:ok, tuned} <- apply_sets(base, sets) do
      case Tuning.validate(LaunchCatalog.catalog(), tuned) do
        :ok -> {:ok, tuned}
        {:error, problems} -> {:error, "invalid tuning: #{inspect(problems)}"}
      end
    end
  end

  defp base_tuning("current"), do: {:ok, Tuning.of(LaunchCatalog.catalog())}

  defp base_tuning("chosen"), do: {:ok, Tuning.chosen()}

  defp base_tuning(path) do
    if File.regular?(path) do
      {term, _binding} = Code.eval_file(path)
      {:ok, term}
    else
      {:error, "--tuning must be current, chosen or a file holding a tuning term: #{path} not found"}
    end
  end

  defp apply_sets(tuning, sets) do
    Enum.reduce_while(sets, {:ok, tuning}, fn set, {:ok, acc} ->
      with [key, raw] <- String.split(set, "=", parts: 2),
           {:ok, updated} <- set_path(acc, String.split(key, "."), raw) do
        {:cont, {:ok, updated}}
      else
        {:error, message} -> {:halt, {:error, "--set #{set}: #{message}"}}
        _ -> {:halt, {:error, "--set #{set}: expected KEY=VALUE"}}
      end
    end)
  end

  # Keys are matched against the tuning's existing keys, so no atom is made from the command line.
  defp set_path(map, [segment | rest], raw) when is_map(map) do
    case Enum.find(Map.keys(map), &(to_string(&1) == segment)) do
      nil ->
        {:error,
         "unknown key #{segment}; one of #{map |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort() |> Enum.join(", ")}"}

      key ->
        with {:ok, value} <- set_path(Map.fetch!(map, key), rest, raw), do: {:ok, Map.put(map, key, value)}
    end
  end

  defp set_path(map, [], _raw) when is_map(map), do: {:error, "is a group, not a value"}
  defp set_path(_value, [_ | _], _raw), do: {:error, "is a value, not a group"}

  defp set_path(current, [], raw) when is_integer(current) do
    case Integer.parse(raw) do
      {n, ""} -> {:ok, n}
      _ -> {:error, "expected an integer"}
    end
  end

  defp set_path(current, [], raw) when is_list(current) do
    values = raw |> String.split(",") |> Enum.map(&Integer.parse/1)

    if Enum.all?(values, &match?({_, ""}, &1)),
      do: {:ok, Enum.map(values, &elem(&1, 0))},
      else: {:error, "expected comma-separated integers"}
  end

  defp set_path(current, [], raw) when is_binary(current), do: {:ok, raw}

  defp progress({day, stats}, days) do
    label = if day == 1, do: "warm-up day", else: "day #{day - 1}/#{days}"
    hall_day = day - 1
    IO.puts("Finished #{label}: #{Stats.day_served(stats, hall_day)} mains served")
  end

  # -- report -------------------------------------------------------------------

  def report(result, args) do
    stats = result.stats

    %{
      run: args.run,
      seed: args.seed,
      via: args.via,
      days: args.days,
      tuning_source: args.tuning,
      set: args.set,
      tuning: result.tuning,
      reference_hours: Tuple.to_list(result.hours),
      reference_cuisine_option: Map.get(args, :cuisine),
      extra_stalls: Map.get(args, :extra_stalls, 0),
      git_commit: git_commit(),
      reference:
        result.reference &&
          Map.take(result.reference, [:stall_id, :restaurant_id, :cuisine, :recipe, :price, :restock]),
      owners: Enum.map(result.owners, &Map.take(&1, [:stall_id, :restaurant_id, :cuisine, :recipe, :price])),
      stalls: stats.stalls,
      summary: Stats.summary(stats),
      checked_hours: Stats.checked_hours(stats),
      rush_hours: Stats.rush_hours(stats),
      verdict: Stats.verdict(args.run, stats),
      warnings: Stats.warnings(stats),
      problems: Enum.map(result.problems, &inspect/1)
    }
  end

  def json(result, args), do: Jason.encode!(report(result, args), pretty: true)

  defp git_commit do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> "unknown"
    end
  rescue
    _ -> "unknown"
  end

  def print(result, args) do
    report = report(result, args)
    stalls = report.stalls |> Map.keys() |> Enum.sort()

    if r = report.reference do
      IO.puts(
        "Reference stall #{r.stall_id} (#{r.restaurant_id}), cuisine #{r.cuisine} " <>
          "(#{if report.reference_cuisine_option, do: "--cuisine", else: "median starter price among unused cuisines"}), " <>
          "main #{r.recipe} at #{r.price}"
      )
    end

    for extra <- Enum.drop(report.owners, 1) do
      IO.puts(
        "Extra owner stall #{extra.stall_id} (#{extra.restaurant_id}), cuisine #{extra.cuisine}, " <>
          "main #{extra.recipe} at #{extra.price}"
      )
    end

    for sid <- stalls do
      meta = report.stalls[sid]
      IO.puts("  #{sid}: #{meta.restaurant} (#{if meta.npc, do: "computer-run", else: "player"}, #{meta.cuisine})")
    end

    IO.puts("\nPer hall hour: arrivals, admitted, mains served, departures by reason (on arrival | after admission);")

    IO.puts(
      "per stall: average orders waiting w, counter busy b (cooking > 0 or handover), raw shares c (cooking > 0), h (handover)"
    )

    for h <- report.summary.hours do
      cells =
        Enum.map_join(stalls, "  ", fn sid ->
          s = h.stalls[sid]
          "#{sid} w#{f(s.waiting)} b#{f(s.busy)} c#{f(s.cooking)} h#{f(s.handover)}"
        end)

      IO.puts(
        "d#{h.day} #{pad(h.hour)}:00 arr #{h.arrivals} adm #{h.admitted} srv #{h.served} " <>
          "left #{reasons(h.left_on_arrival)} | #{reasons(h.left_after_admission)}  hall w/stall #{f(h.hall_waiting_per_stall)}  #{cells}"
      )
    end

    IO.puts("\nPer game day (day 0 is the warm-up):")

    for d <- report.summary.days do
      zero = Enum.map_join(Enum.sort(d.market_zero_ticks), " ", fn {p, n} -> "#{p}:#{n}" end)

      IO.puts(
        "day #{d.day}#{if d.warm_up, do: " (warm-up)", else: ""}: arrivals #{d.arrivals} admitted #{d.admitted} " <>
          "served #{d.served} served share #{f(d.served_share)} left #{reasons(d.left_on_arrival)} | #{reasons(d.left_after_admission)}"
      )

      IO.puts(
        "  business equivalents #{millis(d.equivalents_millis)}; scale used for this day's arrivals " <>
          "#{millis(d.arrival_scale_millis)} (the day before's equivalents or the floor, whichever is larger)"
      )

      if d.profit == %{}, do: IO.puts("  profit: -")

      for {id, p} <- Enum.sort(d.profit) do
        IO.puts(
          "  profit #{id} #{p.profit} (cash change #{p.cash_change}, arrears change #{p.arrears_change})" <>
            "#{if p.distressed, do: " DISTRESSED", else: ""}: revenue #{p.revenue} purchases #{p.purchases} " <>
            "rent+wages #{p.rent_and_wages_charged} other #{p.other}" <>
            if(p.unreadable > 0,
              do: " unexplained remainder #{p.remainder} (#{p.unreadable} unreadable events)",
              else: ""
            )
        )
      end

      IO.puts("  market products at zero (ticks): #{if zero == "", do: "none", else: zero}")

      if report.reference do
        IO.puts(
          "  reference open samples #{d.reference_open_samples}, short of an ingredient #{d.reference_short_samples} " <>
            "#{inspect(d.reference_short_products)}"
        )
      end
    end

    IO.puts(
      "\nChecked hours per stall (measured days): orders waiting w, counter busy b, share of the checked hours open,"
    )

    IO.puts("and for an owner stall the open instants short of an ingredient")

    for c <- report.checked_hours do
      IO.puts(
        "  #{c.stall} #{c.restaurant}: w12 #{f(c.waiting_12)} w19 #{f(c.waiting_19)} b12 #{f(c.busy_12)} b19 #{f(c.busy_19)} " <>
          "w10 #{f(c.waiting_10)} w14-17 #{f(c.waiting_14_17)} open #{f(c.open_share)}" <>
          if(c.short == nil, do: "", else: " short #{c.short}")
      )
    end

    IO.puts(
      "\nRush hours (measured days): arrivals in the hour per day, stalls open (time average), arrivals per open stall"
    )

    for r <- report.rush_hours do
      IO.puts(
        "  #{pad(r.hour)}:00 arrivals #{f(r.arrivals_per_day)} open stalls #{f(r.open_stalls)} " <>
          "arrivals per open stall #{f(r.arrivals_per_open_stall)}"
      )
    end

    IO.puts("\nVerdict (measured days):")

    for row <- report.verdict do
      bounds = "#{if row.low == nil, do: "-", else: row.low}..#{if row.high == nil, do: "-", else: row.high}"

      IO.puts(
        "  #{if row.pass, do: "PASS", else: "FAIL"}  #{String.pad_trailing(row.check, 52)} #{row.value}  [#{bounds}]" <>
          if(row[:hours], do: "  open share by hour " <> reasons(row.hours), else: "")
      )
    end

    IO.puts("\nWarnings:")
    if report.warnings == [], do: IO.puts("  none")

    for w <- report.warnings do
      IO.puts(
        "  #{w.restaurant}: distressed on measured days #{inspect(w.distressed_days)}, arrears at end #{w.arrears_at_end}" <>
          " (its profit understates or omits costs; compare with care)"
      )
    end
  end

  defp reasons(map) when map_size(map) == 0, do: "-"
  defp reasons(map), do: map |> Enum.sort() |> Enum.map_join(",", fn {k, v} -> "#{k}:#{v}" end)
  defp f(v), do: :erlang.float_to_binary(v / 1, decimals: 2)
  defp millis(nil), do: "-"
  defp millis(v), do: :erlang.float_to_binary(v / 1000, decimals: 3)
  defp pad(n), do: String.pad_leading(Integer.to_string(n), 2, "0")
end

unless System.get_env("CUSTOMER_SIM_NO_MAIN"), do: FeudHall.CustomerSim.CLI.main(System.argv())
