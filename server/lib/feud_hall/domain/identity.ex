defmodule FeudHall.Domain.Identity do
  @moduledoc "Service-wide principals, invitation ancestry, and restaurant license admission."
  alias FeudHall.Domain.{Clock, Hall}
  alias FeudHall.Domain.Hall.Management

  @limit 3
  @earning_period 7 * Clock.day()
  @invite_lifetime Clock.service_duration(72 * 60 * 60 * 1_000)
  @reapplication_delay Clock.service_duration(60_000)

  def empty,
    do: %{principals: %{}, devices: %{}, invitations: %{}, applications: %{}, notices: %{}, recovery_codes: %{}}

  def get(control), do: if(control, do: Map.get(control, :identity, empty()), else: empty())
  def principal(state, id), do: state.principals[id]
  def principal_for_device(state, device), do: state.devices[device]
  def owner?(state, id), do: match?(%{owner?: true}, principal(state, id))
  def reviewer?(state, id), do: match?(%{owner?: true, reviewer?: true}, principal(state, id))
  def earning_period, do: @earning_period

  def commands do
    [
      :bootstrap_guest,
      :join_with_invitation,
      :seed_owner,
      :set_license_reviewer,
      :revoke_device,
      :issue_recovery_code,
      :restore_device,
      :issue_invitation,
      :revoke_invitation,
      :redeem_invitation,
      :apply_for_license,
      :withdraw_license_application,
      :review_license_application
    ]
  end

  def decide(state, _now, {:bootstrap_guest, %{device: device, name: name}}, %{actor: {:device, device}, command_id: id}) do
    cond do
      not valid_id?(device) or not valid_text?(name, 40) -> {:error, :invalid_profile}
      Map.has_key?(state.devices, device) -> {:error, :device_already_bound}
      true -> {:ok, [%{type: :guest_profile_created, principal: "P:" <> principal_key(id), device: device, name: name}]}
    end
  end

  def decide(state, now, {:join_with_invitation, %{device: device, name: name, invitation_id: invite}}, ctx) do
    with {:ok, [created]} <- decide(state, now, {:bootstrap_guest, %{device: device, name: name}}, ctx),
         profile = evolve(state, created),
         {:ok, events} <-
           decide(profile, now, {:redeem_invitation, %{invitation_id: invite}}, %{
             ctx
             | actor: {:principal, created.principal}
           }) do
      {:ok, [created | events]}
    end
  end

  def decide(state, _now, {:seed_owner, %{principal: id, reviewer?: reviewer?}}, %{actor: {:system, :admin}})
      when is_boolean(reviewer?) do
    with %{owner?: false} <- principal(state, id) do
      {:ok, [%{type: :owner_admitted, principal: id, parent: nil, admission_route: :seed, reviewer?: reviewer?}]}
    else
      nil -> {:error, :unknown_principal}
      _ -> {:error, :already_owner}
    end
  end

  def decide(state, _now, {:set_license_reviewer, %{principal: id, enabled: enabled}}, %{actor: {:system, :admin}})
      when is_boolean(enabled) do
    if owner?(state, id),
      do: {:ok, [%{type: :license_reviewer_changed, principal: id, reviewer?: enabled}]},
      else: {:error, :unknown_owner}
  end

  def decide(state, _now, {:revoke_device, %{device: device}}, %{actor: {:principal, id}}) do
    if principal_for_device(state, device) == id,
      do: {:ok, [%{type: :device_revoked, device: device}]},
      else: {:error, :forbidden}
  end

  def decide(state, now, {:issue_recovery_code, %{}}, %{actor: {:principal, id}, command_id: cmd}) do
    if principal(state, id) do
      {:ok,
       [
         %{
           type: :recovery_code_issued,
           principal: id,
           recovery_code_id: "R:" <> cmd,
           expires_at: now + Clock.service_duration(20 * 60 * 1_000)
         }
       ]}
    else
      {:error, :unknown_principal}
    end
  end

  def decide(state, now, {:restore_device, %{device: device, recovery_code_id: code}}, %{actor: {:device, device}}) do
    with false <- Map.has_key?(state.devices, device),
         %{principal: principal, expires_at: expires} when now < expires <- state.recovery_codes[code] do
      {:ok, [%{type: :device_restored, device: device, principal: principal, recovery_code_id: code}]}
    else
      _ -> {:error, :recovery_unavailable}
    end
  end

  def decide(state, now, {:issue_invitation, %{}}, %{actor: {:principal, id}, command_id: command_id}) do
    with %{owner?: true, quota: quota} when quota > 0 <- principal(state, id) do
      {:ok,
       [
         %{
           type: :invitation_issued,
           invitation_id: "I:" <> command_id,
           principal: id,
           expires_at: now + @invite_lifetime
         }
       ]}
    else
      %{owner?: true} -> {:error, :no_invitation_quota}
      _ -> {:error, :owner_required}
    end
  end

  def decide(state, now, {:revoke_invitation, %{invitation_id: invite}}, %{actor: {:principal, id}}) do
    case state.invitations[invite] do
      %{principal: ^id, status: :unused, expires_at: deadline} when now < deadline ->
        {:ok, [%{type: :invitation_released, invitation_id: invite, status: :revoked}]}

      _ ->
        {:error, :invitation_unavailable}
    end
  end

  def decide(state, now, {:redeem_invitation, %{invitation_id: invite}}, %{actor: {:principal, id}}) do
    with %{owner?: false} = applicant <- principal(state, id),
         %{status: :unused, principal: parent, expires_at: deadline} when now < deadline <- state.invitations[invite],
         true <- parent != id do
      events = [
        %{type: :invitation_redeemed, invitation_id: invite, principal: id},
        %{type: :owner_admitted, principal: id, parent: parent, admission_route: :invitation, reviewer?: false}
      ]

      {:ok, events ++ supersede(applicant.pending_application, now)}
    else
      %{owner?: true} -> {:error, :already_owner}
      _ -> {:error, :invitation_unavailable}
    end
  end

  def decide(state, now, {:apply_for_license, %{motivation: motivation}}, %{actor: {:principal, id}, command_id: cmd}) do
    with %{owner?: false, proof: proof, pending_application: nil} = account when not is_nil(proof) <-
           principal(state, id),
         true <- is_nil(motivation) or valid_text?(motivation, 500),
         true <- now >= account.apply_after do
      {:ok,
       [
         %{
           type: :license_application_submitted,
           application_id: "L:" <> cmd,
           principal: id,
           proof: proof,
           motivation: motivation,
           at: now
         }
       ]}
    else
      _ -> {:error, :application_unavailable}
    end
  end

  def decide(state, now, {:withdraw_license_application, %{application_id: app}}, %{actor: {:principal, id}}) do
    case state.applications[app] do
      %{principal: ^id, status: :pending} ->
        {:ok, [decision(app, id, :withdrawn, nil, now)]}

      _ ->
        {:error, :application_unavailable}
    end
  end

  def decide(state, now, {:review_license_application, %{application_id: app, decision: outcome, reason: reason}}, %{
        actor: {:principal, reviewer}
      })
      when outcome in [:approved, :rejected] do
    with true <- reviewer?(state, reviewer),
         %{status: :pending, principal: applicant, proof: proof} <- state.applications[app],
         %{owner?: false, proof: ^proof} <- principal(state, applicant),
         true <- applicant != reviewer,
         true <- valid_text?(reason, 500) or (outcome == :approved and is_nil(reason)) do
      events = [decision(app, reviewer, outcome, reason, now)]

      events =
        if outcome == :approved,
          do:
            events ++
              [
                %{
                  type: :owner_admitted,
                  principal: applicant,
                  parent: reviewer,
                  admission_route: :license,
                  reviewer?: false
                }
              ],
          else: events

      {:ok, events}
    else
      _ -> {:error, :review_unavailable}
    end
  end

  def decide(_state, _now, _command, _ctx), do: {:error, :forbidden}

  def expiries(state, now) do
    state.invitations
    |> Enum.filter(fn {_, invite} -> invite.status == :unused and invite.expires_at <= now end)
    |> Enum.sort()
    |> Enum.map(fn {id, _} -> %{type: :invitation_released, invitation_id: id, status: :expired} end)
  end

  def credit_trading(state, id, ms) when ms > 0 do
    case principal(state, id) do
      %{owner?: true, quota: available, outstanding: issued, progress: previous} when available + issued < @limit ->
        total = previous + ms
        earned = min(div(total, @earning_period), @limit - available - issued)
        progress = if available + issued + earned == @limit, do: 0, else: rem(total, @earning_period)
        [%{type: :invitation_trading_credited, principal: id, earned: earned, progress: progress}]

      _ ->
        []
    end
  end

  def shift_proof(state, %{principal: id} = proof) do
    case principal(state, id) do
      %{proof: nil} -> [%{type: :license_eligibility_earned, principal: id, proof: proof}]
      _ -> []
    end
  end

  def evolve(state, %{type: :guest_profile_created, principal: id, device: device, name: name}) do
    profile = %{
      id: id,
      name: name,
      owner?: false,
      reviewer?: false,
      parent: nil,
      admission_route: nil,
      quota: 0,
      outstanding: 0,
      progress: 0,
      proof: nil,
      pending_application: nil,
      apply_after: 0
    }

    state |> put_in([:principals, id], profile) |> put_in([:devices, device], id)
  end

  def evolve(state, %{type: :owner_admitted} = e) do
    update_in(state.principals[e.principal], fn account ->
      %{
        account
        | owner?: true,
          parent: e.parent,
          admission_route: e.admission_route,
          reviewer?: e.reviewer?,
          quota: if(e.admission_route == :seed, do: @limit, else: 0)
      }
    end)
  end

  def evolve(state, %{type: :license_reviewer_changed, principal: id, reviewer?: reviewer?}),
    do: put_in(state.principals[id].reviewer?, reviewer?)

  def evolve(state, %{type: :device_revoked, device: device}), do: put_in(state.devices[device], nil)

  def evolve(state, %{type: :recovery_code_issued} = e) do
    update_in(state.recovery_codes, fn codes ->
      codes
      |> Map.reject(fn {_, code} -> code.principal == e.principal end)
      |> Map.put(e.recovery_code_id, %{principal: e.principal, expires_at: e.expires_at})
    end)
  end

  def evolve(state, %{type: :device_restored} = e) do
    state
    |> put_in([:devices, e.device], e.principal)
    |> update_in([:recovery_codes], &Map.delete(&1, e.recovery_code_id))
  end

  def evolve(state, %{type: :invitation_issued, principal: id, invitation_id: invite, expires_at: deadline}) do
    state
    |> put_in([:invitations, invite], %{principal: id, status: :unused, expires_at: deadline})
    |> update_in([:principals, id], &%{&1 | quota: &1.quota - 1, outstanding: &1.outstanding + 1})
  end

  def evolve(state, %{type: :invitation_released, invitation_id: invite, status: status}) do
    id = state.invitations[invite].principal

    state
    |> put_in([:invitations, invite, :status], status)
    |> update_in([:principals, id], &%{&1 | quota: &1.quota + 1, outstanding: &1.outstanding - 1})
  end

  def evolve(state, %{type: :invitation_redeemed, invitation_id: invite, principal: recipient}) do
    id = state.invitations[invite].principal

    state
    |> update_in([:invitations, invite], &Map.merge(&1, %{status: :redeemed, recipient: recipient}))
    |> update_in([:principals, id, :outstanding], &(&1 - 1))
    |> notice(id, %{code: :invitation_redeemed, invitation_id: invite})
  end

  def evolve(state, %{type: :invitation_trading_credited, principal: id, earned: earned, progress: progress}),
    do: update_in(state.principals[id], &%{&1 | quota: &1.quota + earned, progress: progress})

  def evolve(state, %{type: :license_eligibility_earned, principal: id, proof: proof}),
    do: put_in(state.principals[id].proof, proof)

  def evolve(state, %{type: :license_application_submitted, application_id: app, principal: id} = e) do
    state
    |> put_in([:applications, app], Map.merge(Map.drop(e, [:type]), %{status: :pending, reason: nil}))
    |> put_in([:principals, id, :pending_application], app)
  end

  def evolve(state, %{type: :license_application_decided, application_id: app} = e) do
    id = state.applications[app].principal

    state
    |> update_in(
      [:applications, app],
      &Map.merge(&1, %{status: e.status, reviewer: e.reviewer, reason: e.reason, decided_at: e.at})
    )
    |> update_in([:principals, id], &%{&1 | pending_application: nil, apply_after: e.at + @reapplication_delay})
    |> notice(id, %{code: :license_application_decided, application_id: app, status: e.status, reason: e.reason})
  end

  def observe(%{principals: principals}, _hall, _events) when map_size(principals) == 0, do: []
  def observe(_identity, _hall, []), do: []

  def observe(identity, hall, events) do
    {_, _, chunks} =
      Enum.reduce(events, {identity, hall, []}, fn event, {accounts, before, chunks} ->
        facts = observe_event(accounts, before, event)
        {Enum.reduce(facts, accounts, &evolve(&2, &1)), Hall.evolve(before, event), [facts | chunks]}
      end)

    chunks |> Enum.reverse() |> Enum.concat()
  end

  defp observe_event(accounts, state, %{type: :clock_advanced, to: to} = event) do
    credits =
      if Management.enabled?(state) do
        event
        |> Map.get(:operating, state.demand.operating)
        |> Enum.flat_map(fn rid ->
          restaurant = state.restaurants[rid]
          sale = state.management.last_simulated_sale[rid]

          if restaurant.owner_kind == :principal and is_integer(sale) and Management.solvent?(state, rid) do
            elapsed = max(0, min(to, sale + Clock.day()) - state.now)
            if elapsed > 0, do: credit_trading(accounts, restaurant.owner, elapsed), else: []
          else
            []
          end
        end)
      else
        []
      end

    credits ++ expiries(accounts, to)
  end

  defp observe_event(accounts, state, %{type: :helper_shift_ended} = event) do
    case Management.shift_proof(state, event) do
      nil -> []
      proof -> shift_proof(accounts, proof)
    end
  end

  defp observe_event(_accounts, _state, _event), do: []

  defp principal_key(id), do: :crypto.hash(:sha256, id) |> Base.url_encode64(padding: false)
  defp supersede(nil, _now), do: []
  defp supersede(app, now), do: [decision(app, nil, :superseded, nil, now)]

  defp decision(id, reviewer, status, reason, now),
    do: %{
      type: :license_application_decided,
      application_id: id,
      reviewer: reviewer,
      status: status,
      reason: reason,
      at: now
    }

  defp notice(state, id, notice),
    do: update_in(state.notices, &Map.update(&1, id, [notice], fn prior -> [notice | prior] end))

  defp valid_id?(id), do: is_binary(id) and byte_size(id) in 1..64 and String.printable?(id)

  defp valid_text?(text, max),
    do:
      is_binary(text) and byte_size(text) <= max * 4 and String.valid?(text) and
        String.length(String.trim(text)) in 1..max
end
