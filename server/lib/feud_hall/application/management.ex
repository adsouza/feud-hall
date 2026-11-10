defmodule FeudHall.Application.Management do
  @moduledoc "Authenticated management commands and scoped read models."
  alias FeudHall.Domain.{Clock, Dietary, Identity, Kitchen, Money, Offers, PublicView}
  alias FeudHall.Domain.Hall.Management, as: HallManagement
  alias FeudHall.Domain.Hall.{CounterPlay, Equipment, OperatingPolicy, Population, Progression, Recognition, Staff}

  @guest_commands ~w(request_allowance admit_visit cancel_tray accept_dessert decline_dessert cancel_dessert
    accept_helper_shift leave_helper_shift select_handover report_helper_presence redeem_invitation apply_for_license
    withdraw_license_application revoke_device issue_recovery_code)a ++ CounterPlay.commands()
  @owner_commands ~w(create_restaurant open_stall close_stall unlock_recipe set_menu_price remove_menu_item
    set_substitution_policy submit_purchase_request cancel_purchase_request set_staff_schedule hire_staff set_worker_schedule dismiss_staff set_helper_offers
    reserve_stall cancel_stall_draft join_waitlist leave_waitlist
    set_restock_policy set_pricing_policy request_starter_stock end_helper_shift report_owner_presence set_unattended_policy issue_invitation revoke_invitation)a ++
                    Progression.commands()

  def public_commands,
    do:
      [:bootstrap_guest, :join_with_invitation, :restore_device, :review_license_application] ++
        @guest_commands ++ @owner_commands

  def envelope(control, device, %{command_id: id, command: {kind, payload}}) when is_binary(device) do
    identity = Identity.get(control)
    principal = Identity.principal_for_device(identity, device)

    case authorize(identity, principal, kind, device) do
      {:ok, actor} ->
        payload =
          case kind do
            kind when kind in [:bootstrap_guest, :join_with_invitation, :restore_device, :revoke_device] ->
              Map.put(payload, :device, device)

            :admit_visit ->
              Map.put(payload, :source, :guest)

            _ ->
              payload
          end

        {:ok, %{command_id: id, actor: actor, command: {kind, payload}}}

      error ->
        error
    end
  end

  def envelope(_control, _device, _request), do: {:error, :unauthenticated}

  defp authorize(identity, principal, kind, device)
       when kind in [:bootstrap_guest, :join_with_invitation, :restore_device] do
    if principal == nil and Map.has_key?(identity.devices, device),
      do: {:error, :revoked_device},
      else: {:ok, {:device, device}}
  end

  defp authorize(_identity, nil, _kind, _device), do: {:error, :unauthenticated}
  defp authorize(_identity, principal, kind, _device) when kind in @guest_commands, do: {:ok, {:principal, principal}}

  defp authorize(identity, principal, kind, _device) when kind in @owner_commands do
    if Identity.owner?(identity, principal), do: {:ok, {:principal, principal}}, else: {:error, :owner_required}
  end

  defp authorize(identity, principal, :review_license_application, _device) do
    if Identity.reviewer?(identity, principal), do: {:ok, {:principal, principal}}, else: {:error, :forbidden}
  end

  defp authorize(_identity, _principal, _kind, _device), do: {:error, :forbidden}

  def view(%{state: nil}, _device), do: {:error, :hall_not_initialized}

  def view(runtime, device) do
    state = runtime.state
    identity = Identity.get(runtime.control)
    principal = Identity.principal_for_device(identity, device)
    account = identity.principals[principal]
    public = PublicView.build(state)
    activity = public_activity(state)

    stalls =
      Enum.map(public.stalls, fn stall ->
        restaurant = state.restaurants[stall.restaurant_id]

        Map.merge(stall, %{
          name: restaurant.name,
          cuisine: Progression.cuisine(state.stalls[stall.stall_id], restaurant),
          npc: restaurant.owner_kind == :npc,
          open?: stall.open? and state.access == :open,
          retiring: Population.closing?(state, restaurant.id),
          awards: Recognition.active_awards(state, restaurant.id),
          activity: stall_activity(state, stall.stall_id, activity),
          menu: Map.new(stall.menu, fn {id, price} -> {id, cents(price)} end)
        })
      end)

    hall = %{
      now: state.now,
      access: state.access,
      stalls: stalls,
      position: runtime.position,
      visitor_play: CounterPlay.enabled?(state),
      failed_ventures: public_history(state, identity),
      lease_forecast: lease_forecast(state, public.market),
      cuisines: state.catalog.recipes |> Map.values() |> Enum.map(& &1.cuisine) |> Enum.uniq() |> Enum.sort(),
      dietary_profiles:
        state.catalog.profiles
        |> Map.values()
        |> Enum.filter(& &1.enabled)
        |> Enum.map(& &1.id)
        |> Enum.sort_by(&{&1 != "unrestricted", &1}),
      recipes:
        Map.new(state.catalog.recipes, fn {id, recipe} -> {id, Map.take(recipe, [:id, :kind, :cuisine, :starter])} end)
    }

    {:ok, %{hall: hall, profile: account && private_view(identity, state, account, public.market)}}
  end

  defp public_activity(state) do
    Enum.reduce(state.orders, %{}, fn {_, order}, by_stall ->
      if order.status in Kitchen.stages() do
        sid = state.visits[order.visit].stall
        item = order.tray || order.id
        cooking = if order.status in [:prep, :finish], do: 1, else: 0

        Map.update(by_stall, sid, {MapSet.new([item]), cooking}, fn {items, active} ->
          {MapSet.put(items, item), active + cooking}
        end)
      else
        by_stall
      end
    end)
  end

  defp stall_activity(state, sid, activity) do
    {items, cooking} = Map.get(activity, sid, {MapSet.new(), 0})

    %{
      waiting: MapSet.size(items),
      cooking: cooking,
      handover: state.stalls[sid].counter != nil,
      staffed: state.access == :open and HallManagement.staffed?(state, sid, state.now),
      paused:
        state.access == :open and state.stalls[sid].mode == :closed and
          get_in(state, [:management, :leases, sid, :opening_requested]) == true,
      staging: CounterPlay.task(state, sid) != nil
    }
  end

  defp private_view(identity, state, account, market) do
    principal = account.id
    restaurant_id = state.owners[{:principal, principal}]
    restaurant = state.restaurants[restaurant_id]
    wallet = get_in(state.wallets, [principal, :slices]) || %{}
    available = Enum.reduce(wallet, 0, fn {_, slice}, sum -> sum + slice.amount - slice.reserved end)
    visit = state.visits[state.active_visits[principal]]

    applications =
      identity.applications |> Map.values() |> Enum.filter(&(&1.principal == principal)) |> Enum.sort_by(& &1.at, :desc)

    invitations =
      for {id, invite} <- Enum.sort(identity.invitations),
          invite.principal == principal,
          do: Map.put(Map.take(invite, [:status, :expires_at]), :id, id)

    recovery_codes =
      for {id, code} <- Enum.sort(identity.recovery_codes),
          code.principal == principal and code.expires_at > state.now,
          do: id

    %{
      account:
        Map.take(account, [:id, :name, :owner?, :reviewer?, :parent, :admission_route, :quota, :progress, :proof]),
      balance: cents(available),
      visit: visit_view(state, visit),
      applications: applications,
      invitations: invitations,
      recovery_codes: recovery_codes,
      notices: Enum.take(Map.get(identity.notices, principal, []), 20),
      reviewer_queue: if(account.reviewer?, do: reviewer_queue(identity), else: []),
      work: work_view(state, principal),
      restaurant: if(restaurant, do: restaurant_view(state, restaurant, market), else: nil),
      draft: if(HallManagement.enabled?(state), do: encode_lease(state.management.drafts[principal]), else: nil),
      waitlisted: HallManagement.enabled?(state) and Map.has_key?(state.management.waitlist, principal),
      slots:
        if(account.owner? and (is_nil(restaurant) or Progression.enabled?(state)), do: available_slots(state), else: []),
      ventures: venture_history(state, principal)
    }
  end

  defp lease_forecast(state, market) do
    if Progression.enabled?(state) do
      {start, finish} = HallManagement.starter_schedule(state.now)
      hours = rem(finish - start + 24, 24)

      trading =
        Enum.count(0..(hours - 1), fn offset ->
          not Clock.cleaning?(rem(start + offset, 24) * Clock.hour())
        end)

      margins =
        for recipe <- Map.values(state.catalog.recipes), recipe.starter, into: %{} do
          ingredients =
            Enum.sum(
              Enum.map(recipe.lines, fn line ->
                Money.ceil_div(line.qty * market[line.product].price, 1_000)
              end)
            )

          {recipe.cuisine, cents(recipe.suggested_price - ingredients)}
        end

      %{
        trading_hours: trading,
        wages: cents(trading * Staff.starter_count() * state.management.rules.wage_rate),
        starter_margins: margins
      }
    end
  end

  defp public_history(state, identity) do
    state
    |> get_in([:progression, :history])
    |> Kernel.||(%{})
    |> Map.values()
    |> Enum.filter(&(&1.owner_kind == :principal))
    |> Enum.sort_by(&{-&1.ended_at, &1.id})
    |> Enum.take(30)
    |> Enum.map(fn record ->
      owner = Identity.principal(identity, record.owner)

      record
      |> Map.take([:id, :name, :cuisines, :opened_at, :ended_at, :peak_stalls, :milestones, :awards])
      |> Map.put(:owner_name, owner && owner.name)
    end)
  end

  defp venture_history(state, principal) do
    for {_, record} <-
          Enum.sort_by(get_in(state, [:progression, :history]) || %{}, fn {id, record} -> {-record.ended_at, id} end),
        record.owner_kind == :principal and record.owner == principal do
      record
      |> Map.take([:id, :name, :cuisines, :opened_at, :ended_at, :peak_stalls])
      |> Map.put(:unpaid, cents(record.unpaid))
      |> Map.put(:final_ledger, Map.new(record.final_ledger, fn {account, value} -> {account, cents(value)} end))
    end
  end

  defp reviewer_queue(identity) do
    identity.applications
    |> Map.values()
    |> Enum.filter(&(&1.status == :pending))
    |> Enum.sort_by(&{&1.at, &1.application_id})
    |> Enum.take(30)
    |> Enum.map(&Map.put(&1, :name, identity.principals[&1.principal].name))
  end

  defp available_slots(state) do
    state.layout
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(&HallManagement.lease_quote(state, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&encode_lease/1)
  end

  defp encode_lease(nil), do: nil

  defp encode_lease(slot) do
    slot
    |> Map.take([:stall_id, :tier, :exposure, :rent, :holding, :setup_fee, :expires_at])
    |> Map.merge(%{rent: cents(slot.rent), holding: cents(slot.holding), setup_fee: cents(slot.setup_fee)})
  end

  defp restaurant_view(state, restaurant, market) do
    id = restaurant.id
    market = Map.new(market, fn {product, offer} -> {product, %{price: cents(offer.price), stock: offer.stock}} end)

    inventory =
      restaurant.batches
      |> Map.values()
      |> Enum.group_by(& &1.product)
      |> Map.new(fn {product, lots} ->
        {product, Enum.reduce(lots, 0, &(&1.qty - &1.reserved + &2))}
      end)

    stalls =
      for {sid, %{restaurant: ^id} = stall} <- Enum.sort(state.stalls) do
        lease = get_in(state, [:management, :leases, sid]) || %{}

        Map.merge(Map.take(stall, [:id, :mode, :tier]), %{
          cuisine: Progression.cuisine(stall, restaurant),
          ready_at: Map.get(stall, :ready_at),
          refit_cost: cents(state.management.rules.setup_fee),
          starter_stock: starter_stock(state, id, sid),
          unlock_offers: unlock_offers(state, restaurant, stall),
          menu:
            Map.new(Progression.stall_menu(state, stall, restaurant), fn {recipe, value} -> {recipe, cents(value)} end),
          lease: Map.take(lease, [:start_hour, :end_hour, :helper_offers, :unattended, :workers, :opening_requested]),
          can_open: HallManagement.allow_open(state, sid) == :ok
        })
      end

    %{
      id: id,
      name: restaurant.name,
      cuisine: restaurant.cuisine,
      cuisines: Progression.cuisines(state, restaurant),
      distress_deadline: get_in(state, [:progression, :distress, id]),
      stall_limit: get_in(state, [:catalog, :rules, :progression, :stall_limit]),
      milestones: Recognition.milestones(state, id),
      awards: Recognition.awards(state, id),
      award_review_at: get_in(state, [:progression, :recognition, :next_review]),
      reputation: Recognition.reputation(state, id),
      unpaid: cents(unpaid(state, id)),
      salvage: salvage_view(state, restaurant),
      equipment_salvage: equipment_salvage(state, restaurant),
      unlocked: restaurant.unlocked,
      menu: Map.new(restaurant.menu, fn {recipe, value} -> {recipe, cents(value)} end),
      ledger: Map.new(restaurant.ledger, fn {account, value} -> {account, cents(value)} end),
      starter_stock: starter_stock(state, id),
      reports:
        for(
          report <- List.wrap(get_in(state, [:management, :reports, id])),
          do: %{day: report.day, delta: Map.new(report.delta, fn {account, value} -> {account, cents(value)} end)}
        ),
      available_cash: cents(HallManagement.available_cash(state, id)),
      stalls: stalls,
      market: market,
      inventory: inventory
    }
  end

  defp unlock_offers(state, restaurant, stall) do
    cuisine = Progression.cuisine(stall, restaurant)

    for {id, recipe} <- state.catalog.recipes,
        recipe.cuisine == cuisine,
        known <- [id in restaurant.unlocked],
        {:ok, equipment, events} <- [Equipment.quote(state, restaurant, stall.id, recipe)],
        not known or events != [],
        into: %{} do
      price = if(known, do: 0, else: recipe.unlock_cost) + equipment
      {id, %{cost: cents(price), equipment: cents(equipment), technique: Map.get(recipe, :technique), known: known}}
    end
  end

  defp equipment_salvage(state, restaurant) do
    if Progression.distressed?(state, restaurant.id) do
      for sid <- Progression.stalls(state, restaurant.id),
          event <- Equipment.salvage_events(state, sid),
          do: %{stall_id: sid, technique: event.technique, amount: cents(event.amount)}
    else
      []
    end
  end

  defp unpaid(state, id) do
    id
    |> then(&Progression.stalls(state, &1))
    |> Enum.reduce(Progression.released_debt(state, id), fn sid, total ->
      total + (get_in(state, [:management, :leases, sid, :arrears]) || 0)
    end)
  end

  defp salvage_view(state, restaurant) do
    if Progression.distressed?(state, restaurant.id) do
      for {id, batch} <- Enum.sort(restaurant.batches),
          batch.reserved == 0 and batch.expires_at > state.now,
          do: %{id: id, product: batch.product, qty: batch.qty, amount: cents(Progression.salvage_value(state, batch))}
    else
      []
    end
  end

  defp starter_stock(state, id, sid \\ nil) do
    offer = OperatingPolicy.starter_stock_offer(state, id, sid)
    %{budget: cents(offer.budget), items: Enum.map(offer.items, &Map.take(&1, [:product, :qty]))}
  end

  defp visit_view(_state, nil), do: nil

  defp visit_view(state, visit) do
    tray = state.trays[visit.tray]
    item = if visit.dessert == :accepted, do: {:dessert, visit.dessert_order}, else: {:tray, visit.tray}
    orders = CounterPlay.item_orders(state, item)
    counter = state.stalls[visit.stall].counter

    {stage, estimate} =
      cond do
        Enum.all?(orders, &(&1.status == :served)) ->
          {:served, nil}

        counter && counter.item == item ->
          {:counter, counter.done_at}

        true ->
          phase = if Enum.all?(orders, &(&1.status == :queued_prep)), do: :queued, else: :preparing
          forecast = Kitchen.counter_forecast(state, visit.stall)
          {phase, get_in(forecast, [item, :service_at])}
      end

    %{
      id: visit.id,
      stall: visit.stall,
      tray_status: tray && tray.status,
      dessert: visit.dessert,
      stage: stage,
      estimate: estimate,
      dessert_deadline: visit.dessert_offer_deadline,
      can_cancel: stage == :queued and visit.dessert != :accepted,
      can_cancel_dessert: stage == :queued and visit.dessert == :accepted,
      recipes: Enum.map(orders, & &1.recipe_id)
    }
  end

  defp work_view(state, principal) do
    if HallManagement.enabled?(state) do
      m = state.management
      shift = m.shifts[m.shift_by_principal[principal]]

      offers =
        if shift,
          do: [],
          else:
            for(
              {sid, _} <- Enum.sort(state.stalls),
              {:ok, offer} <- [HallManagement.shift_offer(state, sid, principal)],
              do: Map.merge(offer, %{rate: cents(offer.rate), estimated_pay: cents(offer.estimated_pay)})
            )

      history =
        for {_, %{principal: ^principal, status: :ended} = old} <- m.shifts,
            do:
              old
              |> Map.take([:shift_id, :stall_id, :at, :ended_at, :reason, :qualified, :tasks, :staged])
              |> Map.put(:amount, cents(old.amount))

      %{
        offers: offers,
        active: shift && active_shift(state, shift),
        history: history |> Enum.sort_by(& &1.ended_at, :desc) |> Enum.take(20)
      }
    else
      %{offers: [], active: nil, history: []}
    end
  end

  defp active_shift(state, shift) do
    sid = shift.stall_id
    shift_id = shift.shift_id

    claim =
      case state.management.selections[sid] do
        %{shift_id: ^shift_id} = selection ->
          ready = Kitchen.ready_items(state, sid)
          items = Enum.map(ready, &handover_item(state, &1))
          choice = if selection.choice in ready, do: handover_item(state, selection.choice)

          %{
            id: selection.id,
            deadline: selection.deadline,
            items: items,
            choice: choice,
            auto_item: items |> List.first() |> then(&(&1 && &1.id))
          }

        _ ->
          nil
      end

    handover =
      case state.stalls[sid].counter do
        %{shift_id: ^shift_id, item: item, done_at: done_at} ->
          Map.put(handover_item(state, item), :done_at, done_at)

        _ ->
          nil
      end

    forecast = Kitchen.counter_forecast(state, sid)

    approaching =
      for {item, %{ready_at: ready}} <- Enum.sort_by(forecast, fn {item, timing} -> {timing.ready_at, item} end),
          ready > state.now do
        Map.put(handover_item(state, item), :ready_at, ready)
      end

    stage_task = CounterPlay.task(state, sid)
    stage_offer = CounterPlay.offer(state, sid, shift_id)

    shift
    |> Map.take([:shift_id, :stall_id, :at, :expires_at, :tasks, :staged])
    |> Map.merge(%{
      selection: claim,
      handover: handover,
      approaching: approaching,
      waiting: if(stage_task, do: Enum.map(Kitchen.ready_items(state, sid), &handover_item(state, &1)), else: []),
      staging: stage_task,
      staging_offer: stage_offer,
      prepared: CounterPlay.prepared(state, sid) != nil
    })
  end

  defp handover_item(state, {_kind, id} = item) do
    orders = CounterPlay.item_orders(state, item)
    summary = %{id: id, recipes: Enum.map(orders, & &1.recipe_id)}

    if CounterPlay.enabled?(state) do
      Map.merge(summary, %{
        number: Enum.min_by(orders, & &1.seq).seq + 1,
        queued_at: if(Enum.all?(orders, & &1.ready_at), do: Enum.max_by(orders, & &1.ready_at).ready_at),
        serve_by: CounterPlay.item_deadline(state, item)
      })
    else
      summary
    end
  end

  def quote(%{state: nil}, _device, _params), do: {:error, :hall_not_initialized}

  def quote(runtime, device, %{visit_id: visit_id}) do
    with principal when is_binary(principal) <- Identity.principal_for_device(Identity.get(runtime.control), device),
         %{principal: ^principal, dessert: :offered} = visit <- runtime.state.visits[visit_id] do
      Offers.quote_dessert(runtime.state, visit) |> encode_quote()
    else
      _ -> {:error, :no_dessert_offer}
    end
  end

  def quote(runtime, _device, %{stall_id: sid, main: main, profile_id: profile} = params) do
    state = runtime.state

    with {:ok, requirement} <- Dietary.requirement(state.catalog, profile) do
      visit = %{requirement: requirement, carbs_reserved: 0, carbs_served: 0}
      Offers.quote_tray(state, sid, main, params[:drink], visit) |> encode_quote()
    end
  end

  def quote(_runtime, _device, _params), do: {:error, :invalid_quote}

  defp encode_quote({:ok, quote}) do
    terms = Offers.terms(quote)

    {:ok,
     %{
       total: cents(quote.total),
       earliest_completion: quote.earliest_completion,
       terms: update_in(terms.components, &Enum.map(&1, fn c -> %{c | price: cents(c.price)} end))
     }}
  end

  defp encode_quote(error), do: error
  defp cents(value), do: Money.to_canonical(value)
end
