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

  test "ignores a stray message instead of crashing and losing the pulse count" do
    pid = start_supervised!({TickServer, interval_ms: 20})
    ref = Process.monitor(pid)

    send(pid, :definitely_not_a_tick)

    # A function_clause crash would report DOWN here, and the restarted clock
    # would silently begin counting from 1 again.
    refute_receive {:DOWN, ^ref, :process, ^pid, _reason}, 200
    assert Process.whereis(TickServer) == pid
    assert_receive {:tick, _n}, 1_000
  end

  describe "spec §10.9: the clock does not reference the engine" do
    # The runtime test above shows the clock survives an absent engine, but a
    # call to an unregistered name is a silent no-op, so runtime evidence alone
    # cannot see a reference being added. These read the compiled module the way
    # domain_purity_test.exs does, so an alias, an import, or a bare atom
    # argument (`GenServer.cast(CityEngine, ...)`) all fail the assertion.
    test "CityEngine is absent from TickServer's imports table" do
      called =
        imports_of(TickServer) |> Enum.map(fn {module, _f, _a} -> module end) |> Enum.uniq()

      assert called != [], "read no imports - is the module compiled?"

      refute CityEngine in called,
             "TickServer must not call CityEngine: a crashed engine must not be " <>
               "able to stall or crash the clock"
    end

    test "CityEngine is absent from TickServer's atom table" do
      atoms = atoms_of(TickServer)

      assert TickServer in atoms, "read no atoms - is the module compiled?"

      refute CityEngine in atoms,
             "TickServer must not name CityEngine at all, not even as an " <>
               "argument to GenServer.cast/2"
    end
  end

  test "uses the configured tick_interval_ms when no interval is given" do
    previous = Application.get_env(:armchair_metropolist, :tick_interval_ms)
    Application.put_env(:armchair_metropolist, :tick_interval_ms, 20)
    on_exit(fn -> Application.put_env(:armchair_metropolist, :tick_interval_ms, previous) end)

    start_supervised!(TickServer)

    assert_receive {:tick, 1}, 1_000
    assert_receive {:tick, 2}, 1_000
  end

  defp imports_of(module) do
    {:ok, {^module, [imports: imports]}} = :beam_lib.chunks(:code.which(module), [:imports])
    imports
  end

  defp atoms_of(module) do
    {:ok, {^module, [atoms: atoms]}} = :beam_lib.chunks(:code.which(module), [:atoms])
    Enum.map(atoms, fn {_index, atom} -> atom end)
  end
end
