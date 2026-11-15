defmodule FeudHall.Domain.Hall.Management do
  @moduledoc "Managed leases, staffing windows, attendance and counter-helper coverage."
  alias FeudHall.Domain.{Clock, Kitchen, Money}
  alias FeudHall.Domain.Hall.{CounterPlay, Evolver, OperatingPolicy, Population, Progression, Rooms, Staff}

  @shift_max Clock.service_duration(10 * 60 * 1_000)
  @shift_default Clock.service_duration(5 * 60 * 1_000)
  @shift_quote_window Clock.service_duration(5_000)
  @selection_duration Clock.service_duration(5_000)
  @draft_window Clock.service_duration(10 * 60 * 1_000)
  @attendance_window Clock.service_duration(20_000)
  @transfer_window Clock.service_duration(60 * 60 * 1_000)
  # Quote fields for display only; reservation and lease events never store them.
  @quote_extras [:base_rent, :class_leased, :class_total, :room, :position]

  def commands do
    [
      :enable_management,
      :request_allowance,
      :set_restock_policy,
      :request_starter_stock,
      :set_pricing_policy,
      :reserve_stall,
      :cancel_stall_draft,
      :join_waitlist,
      :leave_waitlist,
      :set_staff_schedule,
      :hire_staff,
      :set_worker_schedule,
      :dismiss_staff,
      :set_helper_offers,
      :accept_helper_shift,
      :leave_helper_shift,
      :end_helper_shift,
      :select_handover,
      :report_owner_presence,
      :report_helper_presence,
      :set_unattended_policy
    ]
  end

  def enabled?(state), do: is_map(state) and Map.has_key?(state, :management)

  def allowance_claimed?(state, principal),
    do: get_in(state, [:management, :allowance_days, principal]) == Clock.day_of(state.now)

  def decide(state, {:enable_management, %{}}, %{actor: {:system, :admin}}) do
    if enabled?(state) or map_size(state.stalls) != 0,
      do: {:error, :management_requires_empty_hall},
      else: {:ok, [%{type: :management_started, rules: rules()}]}
  end

  def decide(state, command, ctx) do
    if enabled?(state), do: decide_managed(state, command, ctx), else: {:error, :management_unavailable}
  end

  defp decide_managed(state, {kind, _} = command, ctx)
       when kind in [:set_restock_policy, :set_pricing_policy, :request_starter_stock],
       do: OperatingPolicy.decide(state, command, ctx)

  defp decide_managed(state, {:reserve_stall, %{stall_id: sid}}, %{actor: {:principal, id}}) do
    with true <- first_location?(state, id),
         false <- Map.has_key?(state.management.drafts, id),
         %{} = quote <- lease_quote(state, sid) do
      {:ok, [draft(quote, id, state.now)]}
    else
      _ -> {:error, :slot_unavailable}
    end
  end

  defp decide_managed(state, {:cancel_stall_draft, %{}}, %{actor: {:principal, id}}) do
    if Map.has_key?(state.management.drafts, id),
      do: {:ok, release_draft(state, id, :declined)},
      else: {:error, :no_draft}
  end

  defp decide_managed(state, {:join_waitlist, %{tiers: tiers}}, %{actor: {:principal, id}}) do
    allowed = [:quiet, :standard, :busy, :prime]

    with true <- first_location?(state, id),
         false <- Map.has_key?(state.management.drafts, id),
         false <- Map.has_key?(state.management.waitlist, id),
         true <- is_list(tiers) and tiers != [] and Enum.all?(tiers, &(&1 in allowed)) do
      event = %{type: :waitlist_joined, principal: id, tiers: Enum.uniq(tiers), priority: state.management.waitlist_seq}
      {:ok, [event | offer_waitlist(Evolver.evolve(state, event))]}
    else
      _ -> {:error, :waitlist_unavailable}
    end
  end

  defp decide_managed(state, {:leave_waitlist, %{}}, %{actor: {:principal, id}}) do
    if Map.has_key?(state.management.waitlist, id) do
      event = %{type: :waitlist_left, principal: id}
      {:ok, [event | release_draft(Evolver.evolve(state, event), id, :declined)]}
    else
      {:error, :waitlist_unavailable}
    end
  end

  defp decide_managed(state, {:request_allowance, %{}}, %{actor: {:principal, id}, command_id: cmd}) do
    day = Clock.day_of(state.now)
    amount = min(1_200, state.catalog.rules.max_allowance_grant)

    cond do
      allowance_claimed?(state, id) ->
        {:error, :allowance_already_claimed}

      state.visitor_fund < amount ->
        {:error, :visitor_fund_exhausted}

      true ->
        {:ok,
         [
           %{type: :visitor_allowance_claimed, principal: id, day: day},
           %{type: :allowance_granted, principal: id, amount: amount, slice_id: "S:" <> cmd}
         ]}
    end
  end

  defp decide_managed(state, {:hire_staff, %{stall_id: sid, role: role, start_hour: start, end_hour: finish}}, ctx) do
    with {:ok, lease} <- owned_stall(state, sid, ctx),
         true <- Staff.role?(role) and Staff.schedule?(start, finish) and map_size(lease.workers) < Staff.max_roster(),
         rid = state.stalls[sid].restaurant,
         true <- available_cash(state, rid) >= Staff.hire_fee() do
      {:ok,
       [
         %{
           type: :worker_hired,
           stall_id: sid,
           restaurant_id: rid,
           worker_id: "W:" <> ctx.command_id,
           role: role,
           start_hour: start,
           end_hour: finish,
           amount: Staff.hire_fee()
         }
       ]}
    else
      _ -> {:error, :hire_unavailable}
    end
  end

  defp decide_managed(
         state,
         {:set_worker_schedule, %{stall_id: sid, worker_id: id, start_hour: start, end_hour: finish}},
         ctx
       ) do
    with {:ok, lease} <- owned_stall(state, sid, ctx),
         true <- Map.has_key?(lease.workers, id) and Staff.schedule?(start, finish) do
      change = %{type: :worker_scheduled, stall_id: sid, worker_id: id, start_hour: start, end_hour: finish}
      {:ok, worker_change(state, sid, id, change)}
    else
      _ -> {:error, :invalid_schedule}
    end
  end

  defp decide_managed(state, {:dismiss_staff, %{stall_id: sid, worker_id: id}}, ctx) do
    with {:ok, lease} <- owned_stall(state, sid, ctx),
         true <- Map.has_key?(lease.workers, id) do
      {:ok, worker_change(state, sid, id, %{type: :worker_dismissed, stall_id: sid, worker_id: id})}
    else
      _ -> {:error, :worker_unavailable}
    end
  end

  defp decide_managed(state, {:set_staff_schedule, %{stall_id: sid, start_hour: start, end_hour: finish}}, ctx)
       when is_integer(start) and is_integer(finish) and start in 0..23 and finish in 0..24 do
    with {:ok, _} <- owned_stall(state, sid, ctx),
         true <- start != finish and rem(finish - start + 24, 24) in 1..12 do
      changes =
        end_stall_shift(state, sid, :reassigned) ++
          [%{type: :staff_schedule_set, stall_id: sid, start_hour: start, end_hour: finish}]

      {:ok, changes ++ enforce(Enum.reduce(changes, state, &Evolver.evolve(&2, &1)))}
    else
      false -> {:error, :invalid_schedule}
      error -> error
    end
  end

  defp decide_managed(state, {:set_helper_offers, %{stall_id: sid, enabled: flag}}, ctx) when is_boolean(flag) do
    with {:ok, _} <- owned_stall(state, sid, ctx) do
      closing = if flag, do: [], else: end_stall_shift(state, sid, :owner_ended)
      {:ok, closing ++ [%{type: :helper_offer_policy_set, stall_id: sid, enabled: flag}]}
    end
  end

  defp decide_managed(state, {:report_owner_presence, %{present: present}}, %{actor: {:principal, id}})
       when is_boolean(present) do
    until = if present, do: state.now + @attendance_window, else: state.now
    event = %{type: :owner_presence_recorded, principal: id, expires_at: until}
    {:ok, [event | enforce(Evolver.evolve(state, event))]}
  end

  defp decide_managed(state, {:report_helper_presence, %{shift_id: id}}, %{actor: {:principal, principal}}) do
    case state.management.shifts[id] do
      %{principal: ^principal, status: :active} ->
        {:ok, [%{type: :helper_presence_recorded, shift_id: id, expires_at: state.now + @attendance_window}]}

      _ ->
        {:error, :shift_unavailable}
    end
  end

  defp decide_managed(state, {:set_unattended_policy, %{stall_id: sid, enabled: flag, cash_floor: floor}}, ctx)
       when is_boolean(flag) do
    with {:ok, _} <- owned_stall(state, sid, ctx),
         true <- Money.non_negative?(floor) do
      event = %{type: :unattended_policy_set, stall_id: sid, enabled: flag, cash_floor: floor}
      {:ok, [event | enforce(Evolver.evolve(state, event))]}
    else
      false -> {:error, :invalid_money}
      error -> error
    end
  end

  defp decide_managed(
         state,
         {:accept_helper_shift, %{stall_id: sid, expires_at: expires, rate: rate, quoted_at: quoted_at}},
         %{
           actor: {:principal, id},
           command_id: cmd
         }
       ) do
    with {:ok, offer} <- shift_offer(state, sid, id),
         true <- valid_shift_terms?(state, offer, quoted_at, expires, rate),
         {:ok, payment} <- reserve_payroll(state, sid, expires) do
      shift = %{
        type: :helper_shift_started,
        shift_id: "H:" <> cmd,
        stall_id: sid,
        principal: id,
        restaurant_id: state.stalls[sid].restaurant,
        worker_id: offer.worker_id,
        at: state.now,
        expires_at: expires,
        rate: rate,
        payment: payment
      }

      {:ok, [shift]}
    else
      false -> {:error, :stale_shift_offer}
      error -> error
    end
  end

  defp decide_managed(state, {:leave_helper_shift, %{shift_id: shift}}, %{actor: {:principal, id}}) do
    case state.management.shifts[shift] do
      %{principal: ^id, status: :active} -> {:ok, [end_shift(state, shift, :left)]}
      _ -> {:error, :shift_unavailable}
    end
  end

  defp decide_managed(state, {:end_helper_shift, %{stall_id: sid}}, ctx) do
    with {:ok, _} <- owned_stall(state, sid, ctx), do: {:ok, end_stall_shift(state, sid, :owner_ended)}
  end

  defp decide_managed(
         state,
         {:select_handover, %{shift_id: shift, selection_id: claim, item_id: id, recipes: recipes}},
         %{actor: {:principal, principal}}
       ) do
    with %{principal: ^principal, status: :active, stall_id: sid} <- state.management.shifts[shift],
         %{id: ^claim, shift_id: ^shift, deadline: deadline} when state.now < deadline <-
           state.management.selections[sid],
         {kind, ^id} <- Enum.find(Kitchen.ready_items(state, sid), &(elem(&1, 1) == id)),
         true <- handover_recipes(state, {kind, id}) == recipes do
      {:ok, [%{type: :helper_choice_selected, stall_id: sid, selection_id: claim, item: %{kind: kind, id: id}}]}
    else
      _ -> {:error, :selection_unavailable}
    end
  end

  defp decide_managed(_state, _command, _ctx), do: {:error, :invalid_management_command}

  defp worker_change(state, sid, id, change) do
    shift = get_in(state, [:management, :shift_by_stall, sid])

    ending =
      cond do
        shift && state.management.shifts[shift].worker_id == id -> end_stall_shift(state, sid, :reassigned)
        match?(%{worker_id: ^id}, CounterPlay.task(state, sid)) -> CounterPlay.interrupt(state, sid)
        true -> []
      end

    changes = ending ++ [change]
    changes ++ enforce(Enum.reduce(changes, state, &Evolver.evolve(&2, &1)))
  end

  def rules do
    %{
      version: 1,
      lease_rates: %{quiet: [8_000, 800], standard: [10_000, 1_000], busy: [15_000, 1_500], prime: [22_000, 2_200]},
      setup_fee: 5_000,
      wage_rate: 650,
      employer_transfer_cap: 20_000,
      hall_transfer_cap: 200_000
    }
  end

  @doc """
  The terms a free spot is offered at now, or nil when it cannot be offered
  (unknown, leased, reserved, or in a closed room). `rent` and `holding` are
  the class's current quote. Pass a `Rooms.summary/1` of the same state to
  quote many spots without recomputing it.
  """
  def lease_quote(state, sid, summary \\ nil) do
    tier = state.layout[sid]

    if enabled?(state) and not is_nil(tier) and not Map.has_key?(state.stalls, sid) and not reserved?(state, sid) do
      summary = summary || Rooms.summary(state)

      if Rooms.open?(state, sid, summary) do
        class = Rooms.quote(summary, tier)
        spot = Map.get(summary.spots, sid, %{room: nil, position: nil})

        %{
          stall_id: sid,
          tier: tier,
          rent: class.rent,
          holding: class.holding,
          setup_fee: state.management.rules.setup_fee,
          exposure: state.catalog.rules.exposure_permille[tier],
          base_rent: class.base_rent,
          class_leased: class.leased,
          class_total: class.total,
          room: spot.room,
          position: spot.position
        }
      end
    end
  end

  def reserved?(state, sid), do: get_in(state, [:management, :draft_by_stall, sid]) != nil

  @doc "The layout a computer-run owner may choose from: unreserved spots in open rooms."
  def npc_layout(state) do
    summary = Rooms.summary(state)
    Map.filter(state.layout, fn {sid, _} -> not reserved?(state, sid) and Rooms.open?(state, sid, summary) end)
  end

  def allow_lease(state, sid, kind, owner) do
    cond do
      not enabled?(state) ->
        :ok

      state.catalog.rules.starter_grant < state.management.rules.setup_fee ->
        {:error, :insufficient_funds}

      kind == :npc and not reserved?(state, sid) ->
        :ok

      kind == :principal and
          match?(%{stall_id: ^sid, expires_at: at} when at > state.now, state.management.drafts[owner]) ->
        :ok

      true ->
        {:error, :slot_unavailable}
    end
  end

  defp draft(quote, id, now),
    do:
      Map.merge(Map.drop(quote, @quote_extras), %{
        type: :stall_draft_reserved,
        principal: id,
        expires_at: now + @draft_window
      })

  def release_draft(state, id, reason) do
    case state.management.drafts[id] do
      nil ->
        []

      current ->
        event = %{type: :stall_draft_released, principal: id, stall_id: current.stall_id, reason: reason}
        [event | offer_waitlist(Evolver.evolve(state, event))]
    end
  end

  def vacancy_events(state), do: offer_waitlist(state)

  @doc """
  Appends waiting-list offers to a batch that leases a spot, evaluated on the
  state after the batch: a lease can open a room. Unmanaged halls and halls
  without the room rule are unchanged, since a lease there frees nothing.
  """
  def with_vacancies(state, events) do
    if enabled?(state) and Rooms.enabled?(state),
      do: events ++ vacancy_events(Enum.reduce(events, state, &Evolver.evolve(&2, &1))),
      else: events
  end

  defp first_location?(state, id) do
    case state.owners[{:principal, id}] do
      nil ->
        true

      rid ->
        Progression.enabled?(state) and not Progression.distressed?(state, rid) and Progression.stalls(state, rid) == []
    end
  end

  defp offer_waitlist(state) do
    state.management.waitlist
    |> Enum.sort_by(fn {_, entry} -> entry.priority end)
    |> Enum.reduce({[], state}, fn {id, entry}, {events, current} ->
      # Drafts change neither rents nor which rooms are open (a draft lies in an
      # open room), so one summary serves this owner's search.
      summary = Rooms.summary(current)

      available =
        current.layout
        |> Enum.sort()
        |> Enum.find_value(fn {sid, tier} -> if tier in entry.tiers, do: lease_quote(current, sid, summary) end)

      if available && not Map.has_key?(current.management.drafts, id) do
        event = draft(available, id, current.now)
        {[event | events], Evolver.evolve(current, event)}
      else
        {events, current}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  def lease_events(state, sid, rid, kind, owner) do
    quote = if kind == :principal and enabled?(state), do: state.management.drafts[owner], else: lease_quote(state, sid)

    if quote, do: [lease_event(state, quote, rid, kind, if(kind == :principal, do: owner))], else: []
  end

  def starter_schedule(now) do
    hour = div(rem(now, Clock.day()), Clock.hour())
    start = if Clock.cleaning?(now), do: 5, else: hour
    {start, rem(start + 12, 24)}
  end

  def lease_event(state, quote, rid, kind, principal) do
    {start, finish} = starter_schedule(state.now)

    Map.merge(Map.drop(quote, [:expires_at | @quote_extras]), %{
      type: :stall_leased,
      restaurant_id: rid,
      start_hour: start,
      end_hour: finish,
      enabled: kind == :npc,
      principal: principal,
      at: state.now
    })
  end

  def allow_open(state, sid) do
    case get_in(state, [:management, :leases, sid]) do
      nil ->
        :ok

      lease ->
        restaurant = state.restaurants[state.stalls[sid].restaurant]

        cond do
          Progression.distressed?(state, restaurant.id) -> {:error, :business_distressed}
          Population.closing?(state, restaurant.id) -> {:error, :npc_retiring}
          Map.get(state.stalls[sid], :ready_at, 0) > state.now -> {:error, :location_refitting}
          not staffed?(state, sid, state.now) -> {:error, :staff_off_duty}
          lease.arrears > 0 -> {:error, :unpaid_rent}
          not operating_authorized?(state, sid, restaurant) -> {:error, :owner_absent}
          true -> :ok
        end
    end
  end

  def staffed?(state, sid, at), do: off_duty_roles(state, sid, at) == []

  @doc "Roles that block opening for lack of on-duty staff; unleased stalls have none."
  def off_duty_roles(state, sid, at) do
    case get_in(state, [:management, :leases, sid]) do
      nil -> []
      lease -> Staff.off_duty_roles(lease.workers, at)
    end
  end

  @doc "Estimate the next eligible opening from the current request, roster and known clock boundaries."
  def estimated_reopening(state, sid) do
    stall = state.stalls[sid]

    if stall.mode == :closed or state.access == :cleaning do
      case get_in(state, [:management, :leases, sid]) do
        %{opening_requested: true} = lease -> next_eligible_opening(state, stall, lease)
        nil when stall.mode == :open -> Clock.next_cleaning_end(state.now)
        _ -> nil
      end
    end
  end

  defp next_eligible_opening(state, stall, lease) do
    day = Clock.day_of(state.now)
    hour = Clock.hour()
    roster = Map.values(lease.workers)
    starts = for d <- day..(day + 1), worker <- roster, do: d * Clock.day() + worker.start_hour * hour
    breaks = for %{break_until: at} <- roster, is_integer(at), do: at
    ready = Map.get(stall, :ready_at, 0)
    refit_boundary = div(ready + hour - 1, hour) * hour

    boundaries = [
      state.management.next_hour,
      refit_boundary,
      Clock.cleaning_end_of(day),
      Clock.cleaning_end_of(day + 1)
    ]

    (boundaries ++ starts ++ breaks)
    |> Enum.filter(&(&1 > state.now and not Clock.cleaning?(&1)))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.find(fn at ->
      future = %{state | now: at}

      future =
        if Enum.any?(breaks, &(&1 <= at)) do
          update_in(future.management.leases[stall.id].workers, fn workers ->
            Map.new(workers, fn
              {id, %{break_until: until} = worker} when is_integer(until) and until <= at ->
                {id, Staff.transition(worker, :recovered, at)}

              entry ->
                entry
            end)
          end)
        else
          future
        end

      allow_open(future, stall.id) == :ok
    end)
  end

  def capacity(state, sid) do
    rules = state.catalog.rules.kitchen

    if get_in(state, [:management, :leases, sid]),
      do: {1, 1},
      else: {rules.prep_stations, rules.finish_stations}
  end

  def solvent?(state, rid) do
    Enum.all?(state.stalls, fn
      {sid, %{restaurant: ^rid}} -> state.management.leases[sid].arrears == 0
      _ -> true
    end)
  end

  def available_cash(state, rid) do
    charges =
      if enabled?(state) do
        Enum.reduce(state.management.leases, 0, fn {sid, lease}, total ->
          if state.stalls[sid].restaurant == rid do
            total + lease.arrears + div(lease.rent_accrued, Clock.day()) + div(lease.wages_accrued, Clock.hour())
          else
            total
          end
        end)
      else
        0
      end

    max(0, cash_after_payroll(state, rid) - charges)
  end

  defp cash_after_payroll(state, rid) do
    ledger = state.restaurants[rid].ledger
    shifts = get_in(state, [:management, :shifts]) || %{}

    held =
      Enum.reduce(shifts, 0, fn
        {_, %{status: :active, restaurant_id: ^rid, payment: payment}}, sum -> sum + Enum.sum(Map.values(payment))
        _, sum -> sum
      end)

    max(0, ledger.cash - held)
  end

  def shift_offer(state, sid, id) do
    with %{helper_offers: true} <- get_in(state, [:management, :leases, sid]),
         %{mode: :open, restaurant: rid} <- state.stalls[sid],
         true <- state.access == :open and staffed?(state, sid, state.now),
         false <-
           Map.has_key?(state.management.shift_by_stall, sid) or Map.has_key?(state.management.shift_by_principal, id),
         false <- state.restaurants[rid].owner == id and state.restaurants[rid].owner_kind == :principal do
      backing = Staff.support(state.management.leases[sid].workers, state.now)
      ends = min(Clock.service_cutoff(state.now), Staff.ends_at(backing, state.now))
      expires = min(state.now + min(@shift_max, @shift_default), ends)

      with true <- expires > state.now,
           {:ok, _} <- reserve_payroll(state, sid, expires) do
        {:ok,
         %{
           stall_id: sid,
           rate: state.management.rules.wage_rate,
           worker_id: backing.id,
           quoted_at: state.now,
           expires_at: expires,
           estimated_pay: wages(state.now, expires, state.management.rules.wage_rate)
         }}
      else
        _ -> {:error, :shift_unavailable}
      end
    else
      _ -> {:error, :shift_unavailable}
    end
  end

  defp valid_shift_terms?(state, offer, quoted_at, expires, rate) do
    is_integer(quoted_at) and quoted_at <= state.now and state.now - quoted_at <= @shift_quote_window and
      rate == offer.rate and is_integer(expires) and expires > state.now and
      expires == min(quoted_at + min(@shift_max, @shift_default), offer.expires_at)
  end

  defp reserve_payroll(state, sid, ending) do
    rid = state.stalls[sid].restaurant
    employer = employer(state.restaurants[rid])
    rate = state.management.rules.wage_rate
    payment = payroll_windows(state.now, ending, rate)
    m = state.management

    fits =
      Enum.all?(payment, fn {window, amount} ->
        total = usage(state, window, nil)
        per_employer = usage(state, window, employer)
        total + amount <= m.rules.hall_transfer_cap and per_employer + amount <= m.rules.employer_transfer_cap
      end)

    if fits and available_cash(state, rid) >= Enum.sum(Map.values(payment)),
      do: {:ok, payment},
      else: {:error, :unfunded_shift}
  end

  defp payroll_windows(start, stop, rate) when stop <= start or rate == 0, do: %{}

  defp payroll_windows(start, stop, rate) do
    Map.new(div(start, @transfer_window)..div(stop - 1, @transfer_window), fn window ->
      left = max(start, window * @transfer_window)
      right = min(stop, (window + 1) * @transfer_window)
      {window, wages(start, right, rate) - wages(start, left, rate)}
    end)
  end

  defp wages(start, stop, rate), do: div((stop - start) * rate, Clock.hour())
  defp employer(restaurant), do: Atom.to_string(restaurant.owner_kind) <> ":" <> restaurant.owner

  defp usage(state, window, owner) do
    m = state.management
    used = Map.get(m.transfer_used, {owner, window}, 0)

    Enum.reduce(m.shifts, used, fn
      {_, %{status: :active, restaurant_id: rid, payment: payment}}, acc ->
        if owner == nil or owner == employer(state.restaurants[rid]), do: acc + Map.get(payment, window, 0), else: acc

      _, acc ->
        acc
    end)
  end

  def end_stall_shift(state, sid, reason) do
    case get_in(state, [:management, :shift_by_stall, sid]) do
      nil -> []
      shift -> [end_shift(state, shift, reason)]
    end
  end

  def recovery_events(state) do
    if enabled?(state) do
      resumed = %{type: :management_resumed}
      endings = end_all(state, :recovery)
      recovered = Enum.reduce(endings ++ [resumed], state, &Evolver.evolve(&2, &1))
      endings ++ [resumed] ++ enforce(recovered)
    else
      []
    end
  end

  defp end_all(state, reason) do
    if enabled?(state),
      do: for({id, %{status: :active}} <- Enum.sort(state.management.shifts), do: end_shift(state, id, reason)),
      else: []
  end

  def end_shift(state, shift, reason) do
    work = state.management.shifts[shift]
    stop = min(state.now, work.expires_at)
    payment = payroll_windows(work.at, stop, work.rate)

    %{
      type: :helper_shift_ended,
      shift_id: shift,
      at: stop,
      reason: reason,
      payment: payment,
      amount: Enum.sum(Map.values(payment)),
      qualified: reason == :scheduled_end and stop == work.expires_at and work.tasks > 0
    }
  end

  def end_principal_shift(%{management: m} = state, principal, reason) do
    case m.shifts[m.shift_by_principal[principal]] do
      %{status: :active, shift_id: shift, stall_id: sid} ->
        selection = if Map.has_key?(m.selections, sid), do: [%{type: :helper_selection_closed, stall_id: sid}], else: []
        selection ++ [end_shift(state, shift, reason)]

      _ ->
        []
    end
  end

  def end_principal_shift(_state, _principal, _reason), do: []

  def shift_proof(state, %{type: :helper_shift_ended, qualified: true} = event) do
    work = state.management.shifts[event.shift_id]

    %{
      principal: work.principal,
      shift_id: work.shift_id,
      hall_id: state.hall_id,
      restaurant_id: work.restaurant_id,
      stall_id: work.stall_id,
      at: work.at,
      expires_at: work.expires_at,
      ended_at: event.at,
      tasks: work.tasks,
      reason: event.reason
    }
  end

  def shift_proof(_state, _event), do: nil

  def start_selection(state, sid) do
    case get_in(state, [:management, :shift_by_stall, sid]) do
      nil ->
        nil

      shift ->
        %{
          type: :helper_selection_opened,
          stall_id: sid,
          shift_id: shift,
          selection_id: "C:#{sid}:#{state.now}",
          deadline: state.now + min(@selection_duration, state.catalog.rules.handover_ms)
        }
    end
  end

  def finish_selection(state, sid) do
    selection = state.management.selections[sid]
    ready = Kitchen.ready_items(state, sid)
    current_shift = state.management.shift_by_stall[sid]
    chosen = selection.choice
    selected? = current_shift == selection.shift_id and chosen in ready
    ended = %{type: :helper_selection_closed, stall_id: sid}

    handover =
      case if(selected?, do: chosen, else: List.first(ready)) do
        {kind, id} ->
          duration = max(1, state.catalog.rules.handover_ms - @selection_duration)

          [
            CounterPlay.shorten(state, %{
              type: :handover_started,
              stall_id: sid,
              item: %{kind: kind, id: id},
              done_at: state.now + duration,
              shift_id: if(selected?, do: current_shift)
            })
          ]

        nil ->
          []
      end

    idle =
      if current_shift == selection.shift_id and chosen == nil and ready != [],
        do: [end_shift(state, current_shift, :actionable_idle)],
        else: []

    [ended | handover] ++ idle
  end

  def handover_proof(state, sid) do
    case get_in(state, [:stalls, sid, :counter, :shift_id]) do
      nil ->
        []

      shift ->
        if get_in(state, [:management, :shifts, shift, :status]) == :active,
          do: [%{type: :helper_task_completed, shift_id: shift}],
          else: []
    end
  end

  def handover_recipes(state, {:tray, id}), do: Enum.map(state.trays[id].components, &state.orders[&1].recipe_id)
  def handover_recipes(state, {:dessert, id}), do: [state.orders[id].recipe_id]

  def boundaries(state) do
    if enabled?(state) do
      m = state.management
      shifts = for {id, %{status: :active, expires_at: at}} <- m.shifts, do: {at, id, {:helper_end, id}}

      absences =
        for {id, %{status: :active, presence_until: at, expires_at: ending}} <- m.shifts,
            at < ending,
            do: {at, id, {:helper_absent, id}}

      selections = for {sid, selection} <- m.selections, do: {selection.deadline, sid, {:selection_end, sid}}
      hourly = [{m.next_hour, "management-hour", {:management_hour}}]
      attend = for {id, at} <- m.presence, do: {at, id, {:attendance, id}}
      staff = staff_boundaries(state)
      drafts = for {id, draft} <- m.drafts, do: {draft.expires_at, id, {:draft_expired, id}}
      shifts ++ absences ++ selections ++ hourly ++ attend ++ drafts ++ staff
    else
      []
    end
  end

  defp staff_boundaries(state) do
    busy = MapSet.new(Kitchen.busy_stalls(state))

    for {sid, lease} <- state.management.leases,
        {at, id, change} <- Staff.boundaries(lease.workers, state.now, working_staff(state, sid, lease, busy)) do
      {at, id, {:staff_condition, sid, id, change}}
    end
  end

  def staff_condition_events(state, sid, id, condition) do
    event = %{type: :staff_condition_changed, stall_id: sid, worker_id: id, condition: condition, at: state.now}

    if condition == :protective_break,
      do: worker_change(state, sid, id, event),
      else: [event | enforce(Evolver.evolve(state, event))]
  end

  def stage_available?(state, sid, role) do
    case get_in(state, [:management, :leases, sid, :workers]) do
      nil -> true
      workers -> Enum.any?(Staff.active(workers, state.now), &(&1.role == role))
    end
  end

  def adapt_course(state, sid, course) do
    case get_in(state, [:management, :leases, sid, :workers]) do
      nil -> course
      workers -> Staff.adapt_course(workers, state.now, course)
    end
  end

  defp working_staff(state, sid, lease, busy) do
    if state.access == :open and (state.stalls[sid].mode == :open or MapSet.member?(busy, sid)),
      do: lease.workers |> Staff.active(state.now) |> MapSet.new(& &1.id),
      else: MapSet.new()
  end

  def enforce(state) do
    if enabled?(state) do
      state.stalls
      |> Enum.sort()
      |> Enum.flat_map(fn {sid, stall} ->
        lease = state.management.leases[sid]
        can_open = allow_open(state, sid) == :ok

        cond do
          stall.mode == :open and not can_open ->
            restaurant = state.restaurants[stall.restaurant]
            present = Map.get(state.management.presence, restaurant.owner, 0) > state.now
            preserve = lease.arrears == 0 and (lease.unattended or present)

            end_stall_shift(state, sid, :safety_stop) ++
              OperatingPolicy.cancel_open_requests(state, sid) ++
              [%{type: :stall_closed, stall_id: sid, preserve_opening: preserve}]

          stall.mode == :closed and state.access == :open and lease.opening_requested and can_open ->
            [%{type: :stall_opened, stall_id: sid}]

          true ->
            []
        end
      end)
      |> Enum.uniq()
    else
      []
    end
  end

  def remove_venture_policies(state, id) do
    state =
      Enum.reduce([:last_simulated_sale, :reports], state, fn field, current ->
        update_in(current, [:management, field], &Map.delete(&1, id))
      end)

    Enum.reduce([:restock, :pricing, :restock_budget], state, fn field, current ->
      update_in(current, [:management, field], &Map.reject(&1, fn {{restaurant, _}, _} -> restaurant == id end))
    end)
  end

  def opening_requested(state, sid, requested?) do
    if get_in(state, [:management, :leases, sid]),
      do: put_in(state.management.leases[sid].opening_requested, requested?),
      else: state
  end

  def cleaning_events(state) do
    if enabled?(state) do
      closes =
        for sid <- Enum.sort(Map.keys(state.management.selections)),
            do: %{type: :helper_selection_closed, stall_id: sid}

      ends =
        for {id, %{status: :active, expires_at: at}} <- Enum.sort(state.management.shifts),
            do: end_shift(state, id, if(at == state.now, do: :scheduled_end, else: :cleaning))

      closes ++ ends
    else
      []
    end
  end

  def accrue(state, elapsed) do
    if enabled?(state) do
      busy = MapSet.new(Kitchen.busy_stalls(state))

      update_in(state.management.leases, fn leases ->
        Map.new(leases, fn {sid, lease} ->
          if Progression.distressed?(state, state.stalls[sid].restaurant) do
            {sid, lease}
          else
            accrue_lease(state, elapsed, busy, sid, lease)
          end
        end)
      end)
    else
      state
    end
  end

  defp accrue_lease(state, elapsed, busy, sid, lease) do
    open? = state.access == :open and state.stalls[sid].mode == :open
    rent = if open?, do: lease.rent, else: lease.holding

    automatic =
      if state.access == :open and (open? or MapSet.member?(busy, sid)) do
        active = length(Staff.active(lease.workers, state.now))
        positions = if Map.has_key?(state.management.shift_by_stall, sid), do: max(active - 1, 0), else: active
        state.management.rules.wage_rate * positions
      else
        0
      end

    workers = Staff.accrue(lease.workers, elapsed, working_staff(state, sid, lease, busy))

    {sid,
     %{
       lease
       | workers: workers,
         rent_accrued: lease.rent_accrued + elapsed * rent,
         wages_accrued: lease.wages_accrued + elapsed * automatic
     }}
  end

  def charge_events(state) do
    leases =
      state.management.leases
      |> Map.keys()
      |> Enum.sort()
      |> Enum.reject(&Progression.distressed?(state, state.stalls[&1].restaurant))

    {events, current} =
      Enum.map_reduce(leases, state, fn sid, current ->
        charge = lease_charge(current, sid)
        {charge, Evolver.evolve(current, charge)}
      end)

    distress = Progression.inspect_after_charges(current)
    current = Enum.reduce(distress, current, &Evolver.evolve(&2, &1))

    events ++ distress ++ [%{type: :management_hour_closed, at: state.management.next_hour}] ++ enforce(current)
  end

  def lease_charge(state, sid) do
    lease = state.management.leases[sid]
    rid = state.stalls[sid].restaurant
    due = lease.arrears + div(lease.rent_accrued, Clock.day()) + div(lease.wages_accrued, Clock.hour())
    amount = min(due, cash_after_payroll(state, rid))

    %{
      type: :operating_costs_charged,
      stall_id: sid,
      restaurant_id: rid,
      amount: amount,
      arrears: due - amount,
      rent_accrued: rem(lease.rent_accrued, Clock.day()),
      wages_accrued: rem(lease.wages_accrued, Clock.hour())
    }
  end

  def record_sale(state, rid, :simulated) do
    if enabled?(state), do: put_in(state.management.last_simulated_sale[rid], state.now), else: state
  end

  def record_sale(state, _rid, _source), do: state

  def report_events(state) do
    if enabled?(state) do
      for {id, restaurant} <- Enum.sort(state.restaurants) do
        previous = state.management.reports[id] |> List.wrap() |> List.first()
        baseline = if previous, do: previous.closing, else: %{}
        delta = Map.new(restaurant.ledger, fn {key, value} -> {key, value - Map.get(baseline, key, 0)} end)

        %{
          type: :business_day_reviewed,
          restaurant_id: id,
          day: Clock.day_of(state.now),
          at: state.now,
          closing: restaurant.ledger,
          delta: delta
        }
      end
    else
      []
    end
  end

  def reset_allowances(state) do
    if enabled?(state) do
      state = %{state | visitor_fund: state.catalog.rules.visitor_fund}
      put_in(state.management.restock_budget, %{})
    else
      state
    end
  end

  def evolve(state, %{type: :management_started, rules: rules}) do
    state
    |> Map.put(:management, %{
      rules: rules,
      leases: %{},
      presence: %{},
      shifts: %{},
      shift_by_stall: %{},
      shift_by_principal: %{},
      selections: %{},
      transfer_used: %{},
      last_simulated_sale: %{},
      allowance_days: %{},
      restock: %{},
      pricing: %{},
      restock_budget: %{},
      drafts: %{},
      draft_by_stall: %{},
      waitlist: %{},
      waitlist_seq: 0,
      reports: %{},
      next_hour: (div(state.now, Clock.hour()) + 1) * Clock.hour()
    })
    |> Progression.start()
  end

  def evolve(state, %{type: :visitor_allowance_claimed, principal: id, day: day}),
    do: put_in(state.management.allowance_days[id], day)

  def evolve(state, %{type: :business_day_reviewed} = e) do
    report = Map.take(e, [:day, :at, :closing, :delta])

    update_in(state.management.reports, fn reports ->
      Map.update(reports, e.restaurant_id, [report], &Enum.take([report | &1], 7))
    end)
  end

  def evolve(state, %{type: :stall_opening_queued, stall_id: sid}), do: opening_requested(state, sid, true)

  def evolve(state, %{type: :management_resumed}),
    do: put_in(state.management.presence, %{}) |> Population.recovered() |> CounterPlay.clear_tasks()

  def evolve(state, %{type: :stall_draft_reserved} = e) do
    state
    |> put_in([:management, :drafts, e.principal], Map.drop(e, [:type]))
    |> put_in([:management, :draft_by_stall, e.stall_id], e.principal)
  end

  def evolve(state, %{type: :stall_draft_released} = e) do
    state
    |> update_in([:management, :drafts], &Map.delete(&1, e.principal))
    |> update_in([:management, :draft_by_stall], &Map.delete(&1, e.stall_id))
    |> update_in([:management, :waitlist], &Map.delete(&1, e.principal))
  end

  def evolve(state, %{type: :waitlist_joined} = e) do
    state
    |> put_in([:management, :waitlist, e.principal], Map.take(e, [:tiers, :priority]))
    |> put_in([:management, :waitlist_seq], e.priority + 1)
  end

  def evolve(state, %{type: :waitlist_left} = e),
    do: update_in(state.management.waitlist, &Map.delete(&1, e.principal))

  def evolve(state, %{type: :stall_leased} = e) do
    lease = %{
      rent: e.rent,
      holding: e.holding,
      start_hour: e.start_hour,
      end_hour: e.end_hour,
      workers: Staff.starter(e.stall_id, e.start_hour, e.end_hour),
      opening_requested: false,
      helper_offers: e.enabled,
      unattended: e.enabled,
      cash_floor: 0,
      arrears: 0,
      rent_accrued: 0,
      wages_accrued: 0
    }

    state =
      if e.principal,
        do: evolve(state, %{type: :stall_draft_released, principal: e.principal, stall_id: e.stall_id}),
        else: state

    state
    |> put_in([:management, :leases, e.stall_id], lease)
    |> debit(e.restaurant_id, e.setup_fee)
    |> Progression.track_lease(e.restaurant_id)
  end

  def evolve(state, %{type: :staff_schedule_set} = e) do
    update_in(state.management.leases[e.stall_id], fn lease ->
      workers =
        Map.new(lease.workers, fn {id, worker} ->
          {id, if(worker.starter, do: %{worker | start_hour: e.start_hour, end_hour: e.end_hour}, else: worker)}
        end)

      %{lease | start_hour: e.start_hour, end_hour: e.end_hour, workers: workers}
    end)
  end

  def evolve(state, %{type: :staff_condition_changed} = e),
    do: update_in(state.management.leases[e.stall_id].workers[e.worker_id], &Staff.transition(&1, e.condition, e.at))

  def evolve(state, %{type: :worker_hired} = e) do
    worker = Staff.worker(e.worker_id, e.role, e.start_hour, e.end_hour, false)

    state
    |> put_in([:management, :leases, e.stall_id, :workers, e.worker_id], worker)
    |> debit(e.restaurant_id, e.amount)
  end

  def evolve(state, %{type: :worker_scheduled} = e) do
    update_in(
      state.management.leases[e.stall_id].workers[e.worker_id],
      &%{&1 | start_hour: e.start_hour, end_hour: e.end_hour}
    )
  end

  def evolve(state, %{type: :worker_dismissed} = e),
    do: update_in(state.management.leases[e.stall_id].workers, &Map.delete(&1, e.worker_id))

  def evolve(state, %{type: :helper_offer_policy_set} = e),
    do: put_in(state.management.leases[e.stall_id].helper_offers, e.enabled)

  def evolve(state, %{type: :owner_presence_recorded, expires_at: at, principal: id}) do
    if at > state.now,
      do: put_in(state.management.presence[id], at),
      else: update_in(state.management.presence, &Map.delete(&1, id))
  end

  def evolve(state, %{type: :management_hour_closed, at: at}) do
    state
    |> put_in([:management, :next_hour], at + Clock.hour())
    |> update_in([:management, :transfer_used], fn used ->
      Map.reject(used, fn {{_employer, window}, _amount} -> window < div(at, @transfer_window) end)
    end)
  end

  def evolve(state, %{type: :unattended_policy_set} = e),
    do: update_in(state.management.leases[e.stall_id], &%{&1 | unattended: e.enabled, cash_floor: e.cash_floor})

  def evolve(state, %{type: :operating_costs_charged} = e) do
    state
    |> update_in(
      [:management, :leases, e.stall_id],
      &%{&1 | arrears: e.arrears, rent_accrued: e.rent_accrued, wages_accrued: e.wages_accrued}
    )
    |> debit(e.restaurant_id, e.amount)
  end

  def evolve(state, %{type: :helper_shift_started} = e) do
    shift = Map.merge(Map.drop(e, [:type]), %{status: :active, tasks: 0, presence_until: e.at + @attendance_window})

    state
    |> CounterPlay.clear_task(e.stall_id)
    |> put_in([:management, :shifts, e.shift_id], shift)
    |> put_in([:management, :shift_by_stall, e.stall_id], e.shift_id)
    |> put_in([:management, :shift_by_principal, e.principal], e.shift_id)
  end

  def evolve(state, %{type: :helper_presence_recorded} = event),
    do: put_in(state.management.shifts[event.shift_id].presence_until, event.expires_at)

  def evolve(state, %{type: :helper_shift_ended} = e) do
    shift = state.management.shifts[e.shift_id]
    employer = employer(state.restaurants[shift.restaurant_id])

    state =
      state
      |> CounterPlay.clear_task(shift.stall_id)
      |> update_in(
        [:management, :shifts, e.shift_id],
        &Map.merge(&1, %{status: :ended, ended_at: e.at, amount: e.amount, reason: e.reason, qualified: e.qualified})
      )
      |> update_in([:management, :shift_by_stall], &Map.delete(&1, shift.stall_id))
      |> update_in([:management, :shift_by_principal], &Map.delete(&1, shift.principal))
      |> debit(shift.restaurant_id, e.amount)

    state =
      Enum.reduce(e.payment, state, fn {window, amount}, current ->
        update_in(current.management.transfer_used, fn used ->
          used
          |> Map.update({employer, window}, amount, &(&1 + amount))
          |> Map.update({nil, window}, amount, &(&1 + amount))
        end)
      end)

    if e.amount > 0 do
      update_in(state.wallets, fn wallets ->
        wallet = Map.get(wallets, shift.principal, %{slices: %{}})

        Map.put(
          wallets,
          shift.principal,
          put_in(wallet.slices["W:" <> e.shift_id], %{source: :earned, amount: e.amount, reserved: 0})
        )
      end)
    else
      state
    end
  end

  def evolve(state, %{type: :helper_selection_opened} = e),
    do:
      put_in(state.management.selections[e.stall_id], %{
        id: e.selection_id,
        shift_id: e.shift_id,
        deadline: e.deadline,
        choice: nil
      })

  def evolve(state, %{type: :helper_choice_selected} = e),
    do: put_in(state.management.selections[e.stall_id].choice, {e.item.kind, e.item.id})

  def evolve(state, %{type: :helper_selection_closed} = e),
    do: update_in(state.management.selections, &Map.delete(&1, e.stall_id))

  def evolve(state, %{type: :helper_task_completed, shift_id: shift}),
    do: update_in(state.management.shifts[shift].tasks, &(&1 + 1))

  def evolve(state, %{type: type} = event)
      when type in [:restock_policy_set, :pricing_policy_set, :restock_budget_reserved, :pricing_policy_applied],
      do: OperatingPolicy.evolve(state, event)

  defp debit(state, rid, amount) do
    update_in(state.restaurants[rid].ledger, fn ledger ->
      ledger
      |> Map.update!(:cash, fn cash -> cash - amount end)
      |> Map.update(:operating_cost, amount, fn cost -> cost + amount end)
    end)
  end

  defp operating_authorized?(_state, _sid, %{owner_kind: :npc}), do: true

  defp operating_authorized?(state, sid, restaurant) do
    m = state.management
    lease = m.leases[sid]

    Map.get(m.presence, restaurant.owner, 0) > state.now or
      (lease.unattended and available_cash(state, restaurant.id) >= lease.cash_floor)
  end

  defp owned_stall(state, sid, %{actor: {kind, owner}}) when kind in [:principal, :npc] do
    with %{restaurant: rid} <- state.stalls[sid],
         %{owner_kind: ^kind, owner: ^owner} <- state.restaurants[rid],
         %{} = lease <- state.management.leases[sid] do
      {:ok, lease}
    else
      _ -> {:error, :forbidden}
    end
  end

  defp owned_stall(_state, _sid, _ctx), do: {:error, :forbidden}
end
