defmodule ArmchairMetropolist.Infrastructure.Simulation.TickServerTest do
  @moduledoc """
  The clock is deliberately ignorant of the engine: it broadcasts and forgets.
  These tests pin that down, because a clock that knows about the engine can be
  stalled or killed by it.
  """

  # async: false — the server registers under its module name.
  use ExUnit.Case, async: false

  alias ArmchairMetropolist.Infrastructure.Simulation.CityEngine
  alias ArmchairMetropolist.Infrastructure.Simulation.TickServer

  @topic "city_tick"

  setup do
    # The subscription is owned by the test process and PubSub drops it when
    # that process exits, so no explicit unsubscribe is needed.
    :ok = Phoenix.PubSub.subscribe(ArmchairMetropolist.PubSub, @topic)
  end

  test "broadcasts a monotonically increasing tick counter on \"city_tick\"" do
    start_supervised!({TickServer, interval_ms: 20})

    assert_receive {:tick, 1}, 1_000
    assert_receive {:tick, 2}, 1_000
    assert_receive {:tick, 3}, 1_000
  end

  test "keeps ticking with no CityEngine running" do
    refute Process.whereis(CityEngine),
           "this test is only meaningful when no engine is running"

    start_supervised!({TickServer, interval_ms: 20})

    assert_receive {:tick, 1}, 1_000
    assert_receive {:tick, 4}, 1_000
    assert Process.whereis(TickServer), "the clock must outlive the absent engine"
  end

  test "uses the configured tick_interval_ms when no interval is given" do
    previous = Application.get_env(:armchair_metropolist, :tick_interval_ms)
    Application.put_env(:armchair_metropolist, :tick_interval_ms, 20)
    on_exit(fn -> Application.put_env(:armchair_metropolist, :tick_interval_ms, previous) end)

    start_supervised!(TickServer)

    assert_receive {:tick, 1}, 1_000
    assert_receive {:tick, 2}, 1_000
  end
end
