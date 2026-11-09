defmodule FeudHall.Domain.ClockTest do
  use ExUnit.Case, async: true

  alias FeudHall.Domain.Clock

  test "one game day is one real hour and 03:00-05:00 is five available real minutes" do
    assert Clock.day() == Clock.service_duration(3_600_000)
    assert Clock.cleaning_end_of(0) - Clock.cleaning_start_of(0) == Clock.service_duration(300_000)
  end

  test "cleaning is the half-open window [03:00, 05:00) on every day" do
    for day <- [0, 1, 6] do
      start = Clock.cleaning_start_of(day)
      stop = Clock.cleaning_end_of(day)
      refute Clock.cleaning?(start - 1)
      assert Clock.cleaning?(start)
      assert Clock.cleaning?(stop - 1)
      refute Clock.cleaning?(stop)
    end
  end

  test "the service cutoff is the next 03:00, or now when exactly 03:00" do
    three = Clock.cleaning_start_of(0)
    assert Clock.service_cutoff(0) == three
    assert Clock.service_cutoff(three - 1) == three
    assert Clock.service_cutoff(three) == three
    assert Clock.service_cutoff(three + 1) == Clock.cleaning_start_of(1)
    assert Clock.next_cleaning_start(three) == Clock.cleaning_start_of(1)
  end

  test "service durations convert exactly into hall ticks" do
    assert Clock.service_duration(30_000) == 12 * Clock.minute()
    assert Clock.service_ms(Clock.hall_at_service(12_345)) == 12_345
    assert Clock.format(Clock.cleaning_start_of(2) + 7 * Clock.minute()) == "day 2 03:07"
  end
end
