defmodule FeudHall.Domain.KitchenTest do
  use ExUnit.Case, async: true

  alias FeudHall.Domain.{Clock, Kitchen, Offers}
  alias FeudHall.Fixtures

  @stall "s001"
  @main %{prep_ms: 100, finish_ms: 10}

  # A real initialised state with small round kitchen numbers so expected
  # completions can be written out by hand. Orders and trays are added by hand
  # to place work in exact stages; `seq` follows insertion order.
  defp base(opts \\ []) do
    {state, _log} = Fixtures.stocked_world()
    kitchen = %{prep_stations: 2, finish_stations: 1, queue_limit: 6}
    kitchen = Map.merge(kitchen, Map.new(Keyword.get(opts, :kitchen, [])))

    state
    |> put_in([:catalog, :rules, :kitchen], kitchen)
    |> put_in([:catalog, :rules, :handover_ms], 5)
    |> put_in([:visits, "V:x"], %{stall: @stall})
  end

  defp put_order(state, id, fields) do
    fields = Map.new(fields)

    order =
      Map.merge(
        %{
          id: id,
          visit: "V:x",
          tray: "T:" <> id,
          kind: :main,
          status: Map.get(fields, :stage, :queued_prep),
          seq: map_size(state.orders),
          queued_at: state.now,
          ready_at: state.now,
          prep_ms: 100,
          finish_ms: 10
        },
        Map.delete(fields, :stage)
      )

    put_in(state, [:orders, id], order)
  end

  defp estimate(state, components \\ [@main]),
    do: Kitchen.estimate(state, @stall, components, state.now).earliest_completion

  test "an empty stall completes at now + prep + finish + handover" do
    state = base()
    assert estimate(state) == state.now + 100 + 10 + 5
  end

  test "two prep stations run two mains in parallel and the third waits" do
    state =
      base()
      |> put_order("A", stage: :queued_prep)
      |> put_order("B", stage: :queued_prep)

    # A and B prepare 0..100; the new main prepares 100..200. Finishing is
    # serial: A 100..110, B 110..120, new 200..210. Handover follows each.
    assert estimate(state) == state.now + 215

    roomy = base(kitchen: [prep_stations: 3])

    roomy =
      roomy |> put_order("A", stage: :queued_prep) |> put_order("B", stage: :queued_prep)

    # With a third station the new main prepares 0..100 and finishes 120..130.
    assert estimate(roomy) == roomy.now + 135
  end

  test "one finish station serialises the finishes of a tray's components" do
    components = [@main, %{prep_ms: 100, finish_ms: 10}]
    state = base()
    assert estimate(state, components) == state.now + 125

    two = base(kitchen: [finish_stations: 2])
    assert estimate(two, components) == two.now + 115
  end

  test "orders already in prep or finish occupy their stations until stage_done_at" do
    state =
      base()
      |> put_order("A", stage: :prep, stage_done_at: 60 + base().now)
      |> put_order("B", stage: :prep, stage_done_at: 80 + base().now)

    # Stations free at 60 and 80: the new main prepares 60..160, finishes 160..170.
    # A finishes 60..70 and B 80..90, handed over before the new tray is ready.
    assert estimate(state) == state.now + 175

    finishing = base() |> put_order("F", stage: :finish, stage_done_at: base().now + 300)
    # The only finish station is busy until 300; counter handover for F is 300..305.
    assert estimate(finishing) == finishing.now + 315
  end

  test "a busy counter delays handover" do
    state = base()
    busy = put_in(state, [:stalls, @stall, :counter], %{item: {:tray, "T:other"}, done_at: state.now + 500})
    assert estimate(busy) == state.now + 505
  end

  test "ready trays hand over in ready order ahead of a later tray" do
    state = base() |> put_order("R", stage: :ready)
    # R is ready now: handover now..now+5; the new tray is ready at 110.
    assert estimate(state) == state.now + 115
  end

  test "a ready tray in hand at the counter is not queued again" do
    state =
      base()
      |> put_order("H", stage: :ready, tray: "T:H")
      |> put_in([:stalls, @stall, :counter], %{item: {:tray, "T:H"}, done_at: base().now + 3})

    # H is in hand until 3, so the new tray (ready at 0) hands over 3..8. Were
    # H re-queued ahead of it, the new tray would wait until 13.
    quick = [%{prep_ms: 0, finish_ms: 0}]
    assert estimate(state, quick) == state.now + 3 + 5
  end

  test "a queued_finish order is released at now" do
    state = base() |> put_order("Q", stage: :queued_finish)
    # Q finishes 0..10 and hands over 10..15; the new main prepares 0..100
    # and finishes 100..110 (the station is free again), handing over 110..115.
    assert estimate(state) == state.now + 115

    # With a new component needing no prep, it queues behind Q's finish.
    assert estimate(state, [%{prep_ms: 0, finish_ms: 10}]) == state.now + 20 + 5
  end

  test "settled orders leave the estimate unchanged" do
    state = base() |> put_order("S", stage: :served) |> put_order("C", stage: :cancelled)
    assert estimate(state) == state.now + 115
  end

  test "ready items hand over FIFO by ready time, not by acceptance" do
    # B was accepted after A but became ready first: B takes the counter 0..5.
    # A is ready at 3 and the new tray (its finish waits for A's station) also
    # at 3; the tie goes to A by acceptance, so A hands over 5..10, new 10..15.
    state =
      base()
      |> put_order("A", stage: :finish, stage_done_at: base().now + 3)
      |> put_order("B", stage: :ready, ready_at: base().now)

    assert Kitchen.next_start(state, @stall) == {:handover, {:tray, "T:B"}}
    assert estimate(state, [%{prep_ms: 0, finish_ms: 0}]) == state.now + 15
  end

  test "dispatch starts prep FIFO by queue time then acceptance, up to the station count" do
    state =
      base()
      |> Map.put(:now, 2)
      |> put_order("late", stage: :queued_prep, queued_at: 2)
      |> put_order("first", stage: :queued_prep, queued_at: 1)
      |> put_order("second", stage: :queued_prep, queued_at: 1)

    assert Kitchen.next_start(state, @stall) == {:prep, "first"}
    busy = state |> put_in([:orders, "first", :status], :prep) |> put_in([:orders, "second", :status], :prep)
    assert Kitchen.next_start(busy, @stall) == nil
  end

  test "other stalls' orders do not occupy this stall" do
    state =
      base()
      |> put_in([:visits, "V:y"], %{stall: "s002"})
      |> put_order("A", stage: :queued_prep, visit: "V:y")
      |> put_order("B", stage: :queued_prep, visit: "V:y")

    assert estimate(state) == state.now + 115
  end

  describe "accepting?/2 and open_stall/2" do
    defp with_queue(state, trays, desserts) do
      state =
        Enum.reduce(1..trays//1, state, fn i, s ->
          put_in(s, [:trays, "T:q#{i}"], %{id: "T:q#{i}", stall: @stall, status: :accepted})
        end)

      Enum.reduce(1..desserts//1, state, fn i, s ->
        put_order(s, "D#{i}", kind: :dessert, stage: :queued_prep)
      end)
    end

    test "a full queue of trays and desserts is refused" do
      full = with_queue(base(), 4, 2)
      refute Kitchen.accepting?(full, @stall)
      assert {:error, :queue_full} = Offers.open_stall_for_main(full, @stall)

      room = with_queue(base(), 4, 1)
      assert Kitchen.accepting?(room, @stall)
      assert {:ok, _stall, _restaurant} = Offers.open_stall_for_main(room, @stall)
    end

    test "the queue limit refuses a new main tray but not a dessert quote" do
      {state, _} = Fixtures.stocked_world()
      full = with_queue(state, 6, 0)
      refute Kitchen.accepting?(full, @stall)

      assert {:error, :queue_full} = Offers.quote_tray(full, @stall, "bean_tacos", nil, blank())
      assert {:ok, _stall, _restaurant} = Offers.open_stall(full, @stall)

      visit = Map.merge(blank(), %{stall: @stall})
      assert {:ok, quote} = Offers.quote_dessert(full, visit)
      assert [%{kind: :dessert}] = quote.components
    end

    test "served and cancelled trays and desserts leave the queue" do
      state =
        with_queue(base(), 6, 0)
        |> update_in([:trays, "T:q1", :status], fn _ -> :served end)

      assert Kitchen.accepting?(state, @stall)
    end

    test "another stall's queue does not count" do
      state = put_in(with_queue(base(), 6, 0), [:visits, "V:x"], %{stall: "s002"})
      state = Enum.reduce(Map.keys(state.trays), state, &put_in(&2, [:trays, &1, :stall], "s002"))
      assert Kitchen.accepting?(state, @stall)
    end
  end

  describe "queue-aware quotes" do
    defp blank do
      {state, _} = Fixtures.stocked_world()
      {:ok, req} = FeudHall.Domain.Dietary.requirement(state.catalog, "unrestricted")
      %{requirement: req, carbs_reserved: 0, carbs_served: 0}
    end

    test "a quote's earliest_completion equals Kitchen.estimate/4 for the same inputs" do
      {state, _} = Fixtures.stocked_world()
      state = put_order(state, "A", stage: :queued_prep)
      {:ok, quote} = Offers.quote_tray(state, @stall, "bean_tacos", "horchata", blank())
      expected = Kitchen.estimate(state, @stall, quote.components, state.now)
      assert quote.earliest_completion == expected.earliest_completion
      assert quote.earliest_completion > state.now
    end

    test "the 03:00 check uses the queue-aware estimate" do
      {state, _} = Fixtures.stocked_world()
      cutoff = Clock.service_cutoff(state.now)

      assert {:ok, _} = Offers.quote_tray(state, @stall, "bean_tacos", nil, blank())

      busy = put_in(state, [:stalls, @stall, :counter], %{item: {:tray, "T:other"}, done_at: cutoff - 1_000})
      assert {:error, :cannot_finish_before_cleaning} = Offers.quote_tray(busy, @stall, "bean_tacos", nil, blank())
    end
  end
end
