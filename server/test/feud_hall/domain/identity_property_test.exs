defmodule FeudHall.Domain.IdentityPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias FeudHall.Domain.Identity

  property "elapsed intervals earn whole entitlements and bank no time above the cap" do
    check all(
            intervals <- list_of(integer(1..(10 * Identity.earning_period())), min_length: 1, max_length: 20),
            max_runs: 35
          ) do
      empty = Identity.empty()
      account = "guest"

      initial =
        Identity.evolve(empty, %{type: :guest_profile_created, principal: account, device: "device", name: "Guest"})

      initial =
        Identity.evolve(initial, %{
          type: :owner_admitted,
          principal: account,
          parent: "sponsor",
          admission_route: :invitation,
          reviewer?: false
        })

      period = Identity.earning_period()

      {state, _total} =
        Enum.reduce(intervals, {initial, 0}, fn duration, {state, elapsed} ->
          next = Enum.reduce(Identity.credit_trading(state, account, duration), state, &Identity.evolve(&2, &1))
          expected = elapsed + duration
          principal = Identity.principal(next, account)
          assert principal.quota == min(3, div(expected, period))
          assert principal.progress == if(expected >= 3 * period, do: 0, else: rem(expected, period))
          {next, expected}
        end)

      assert Identity.principal(state, account).quota + Identity.principal(state, account).outstanding <= 3
    end
  end

  test "issuing and expiring a code returns one entitlement, even on a later tick" do
    owner = "owner"

    identity =
      Identity.evolve(Identity.empty(), %{type: :guest_profile_created, principal: owner, device: "d", name: "Root"})

    identity =
      Identity.evolve(identity, %{
        type: :owner_admitted,
        principal: owner,
        parent: nil,
        admission_route: :seed,
        reviewer?: true
      })

    assert {:ok, [event]} =
             Identity.decide(identity, 0, {:issue_invitation, %{}}, %{actor: {:principal, owner}, command_id: "i"})

    issued = Identity.evolve(identity, event)
    assert Identity.principal(issued, owner).quota == 2
    assert Identity.expiries(issued, event.expires_at - 1) == []
    assert [expired] = Identity.expiries(issued, event.expires_at)
    settled = Identity.evolve(issued, expired)
    assert Identity.principal(settled, owner).quota == 3
    assert Identity.expiries(settled, event.expires_at + 1) == []
  end
end
