defmodule ArmchairMetropolist.Infrastructure.Simulation.CityEngineTest do
  @moduledoc """
  Engine lifecycle tests.

  `async: false` throughout: these mutate application env (to inject the stub
  adapters) and the engine registers under its module name.

  Ticks are injected by broadcasting on `"city_tick"` rather than by waiting on
  the real clock, so nothing here depends on timers. `CityEngine.snapshot/0` is
  used as a synchronisation barrier — it is a `GenServer.call`, so when it
  returns, every tick broadcast before it has already been handled.
  """
  use ExUnit.Case, async: false

  alias ArmchairMetropolist.Domain.Entities.CityMap
  alias ArmchairMetropolist.Domain.Entities.Node
  alias ArmchairMetropolist.Infrastructure.Simulation.CityEngine
  alias ArmchairMetropolist.SlowSnapshotRepository
  alias ArmchairMetropolist.StubNotifier
  alias ArmchairMetropolist.StubSnapshotRepository

  @tick_topic "city_tick"
  @simulation_topic "city_simulation"

  @overridden_keys [
    :snapshot_repository,
    :notifier,
    :notifier_test_pid,
    :checkpoint_every_ticks
  ]

  setup do
    previous =
      Map.new(@overridden_keys, fn key ->
        {key, Application.get_env(:armchair_metropolist, key)}
      end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:armchair_metropolist, key)
        {key, value} -> Application.put_env(:armchair_metropolist, key, value)
      end)
    end)

    Application.put_env(:armchair_metropolist, :snapshot_repository, StubSnapshotRepository)
    Application.put_env(:armchair_metropolist, :notifier, StubNotifier)
    Application.put_env(:armchair_metropolist, :notifier_test_pid, self())

    start_supervised!(StubSnapshotRepository)

    :ok
  end

  describe "hydration" do
    test "hydrates from the latest stored snapshot" do
      city = CityMap.put_node(CityMap.new(40, 30), Node.new(1, 1, :power_plant))
      stored = %{city | tick: 7}

      StubSnapshotRepository.set_initial({:ok, {7, stored}})
      start_supervised!(CityEngine)

      assert {:ok, %{city_map: city_map, metrics: metrics}} = CityEngine.snapshot()
      assert city_map == stored
      assert city_map.tick == 7
      assert metrics.tick == 7
      assert metrics.node_count == 1
    end

    test "falls back to an empty configured grid when nothing is stored" do
      StubSnapshotRepository.set_initial({:error, :not_found})
      start_supervised!(CityEngine)

      assert {:ok, %{city_map: city_map, metrics: metrics}} = CityEngine.snapshot()
      assert city_map.width == 40
      assert city_map.height == 30
      assert city_map.tick == 0
      assert CityMap.nodes(city_map) == []
      assert metrics.node_count == 0
    end

    @tag :capture_log
    test "falls back to an empty grid when the repository errors" do
      StubSnapshotRepository.set_initial({:error, :checksum_mismatch})
      start_supervised!(CityEngine)

      assert {:ok, %{city_map: city_map}} = CityEngine.snapshot()
      assert CityMap.nodes(city_map) == []
    end

    test "start_link/1 returns before a slow repository has answered" do
      # Hydration must happen in handle_continue/2, not init/1: a snapshot read
      # inside init/1 blocks the caller, which at boot is the whole supervision
      # tree. This adapter stalls for 400ms, so start_link/1 taking that long
      # is the signature of the read having moved into init/1.
      Application.put_env(:armchair_metropolist, :snapshot_repository, SlowSnapshotRepository)
      StubSnapshotRepository.set_initial({:error, :not_found})

      {micros, _pid} = :timer.tc(fn -> start_supervised!(CityEngine) end)
      elapsed_ms = div(micros, 1000)

      assert elapsed_ms < 200,
             "start_link must not block on hydration - hydrate in handle_continue, " <>
               "not init/1 (took #{elapsed_ms}ms, repository stalls for " <>
               "#{SlowSnapshotRepository.delay_ms()}ms)"

      # ...and the hydration it deferred still completes.
      assert {:ok, %{city_map: city_map}} = CityEngine.snapshot()
      assert city_map.width == 40
      assert city_map.height == 30
    end
  end

  describe "ticks" do
    test "broadcasts a delta and metrics for every tick on \"city_tick\"" do
      StubSnapshotRepository.set_initial({:ok, {0, starved_city()}})
      start_supervised!(CityEngine)
      subscribe_simulation()

      broadcast_tick(1)

      assert_receive {:city_delta, delta}, 1_000
      assert_receive {:city_metrics, metrics}, 1_000

      # Ten starved consumers all lose enough health to change their display
      # signature, so they all appear in the delta.
      assert map_size(delta) == 10
      assert %Node{} = delta[Node.id(0, 0)]
      assert delta[Node.id(0, 0)].health < 100.0

      assert metrics.tick == 1
      assert metrics.node_count == 10
      assert metrics.resources.power.satisfaction < 1.0
    end

    test "advances city_map.tick and ignores the clock's counter" do
      StubSnapshotRepository.set_initial({:ok, {0, CityMap.new(40, 30)}})
      start_supervised!(CityEngine)

      # Clock pulse numbers are diagnostic only: an out-of-order or restarted
      # clock must not move the authoritative simulation tick.
      broadcast_tick(99)
      broadcast_tick(1)

      assert {:ok, %{city_map: city_map, metrics: metrics}} = CityEngine.snapshot()
      assert city_map.tick == 2
      assert metrics.tick == 2
    end
  end

  describe "infrastructure commands" do
    setup do
      StubSnapshotRepository.set_initial({:error, :not_found})
      start_supervised!(CityEngine)
      :ok
    end

    test "place/3 adds the node and broadcasts it" do
      subscribe_simulation()

      assert {:ok, %Node{} = node} = CityEngine.place(3, 4, :power_plant)
      assert node.id == Node.id(3, 4)
      assert node.type == :power_plant
      assert_receive {:city_node_placed, ^node}, 1_000

      assert {:ok, %{city_map: city_map}} = CityEngine.snapshot()
      assert CityMap.get_node(city_map, 3, 4) == node
    end

    test "demolish/2 removes the node and broadcasts its id" do
      {:ok, node} = CityEngine.place(3, 4, :power_plant)
      subscribe_simulation()

      assert {:ok, id} = CityEngine.demolish(3, 4)
      assert id == node.id
      assert_receive {:city_node_removed, ^id}, 1_000

      assert {:ok, %{city_map: city_map}} = CityEngine.snapshot()
      refute CityMap.occupied?(city_map, 3, 4)
    end

    test "place/3 on an occupied cell returns an error and broadcasts nothing" do
      {:ok, _node} = CityEngine.place(3, 4, :power_plant)
      subscribe_simulation()

      assert {:error, :occupied} = CityEngine.place(3, 4, :commercial)
      refute_receive {:city_node_placed, _}, 200

      assert {:ok, %{city_map: city_map}} = CityEngine.snapshot()
      assert CityMap.get_node(city_map, 3, 4).type == :power_plant
    end

    test "rejects out-of-bounds coordinates and unknown types" do
      subscribe_simulation()

      assert {:error, :out_of_bounds} = CityEngine.place(40, 0, :park)
      assert {:error, :unknown_type} = CityEngine.place(1, 1, :space_elevator)
      refute_receive {:city_node_placed, _}, 200
    end

    test "demolish/2 on an empty cell returns an error and broadcasts nothing" do
      subscribe_simulation()

      assert {:error, :empty} = CityEngine.demolish(5, 5)
      refute_receive {:city_node_removed, _}, 200
    end
  end

  describe "persistence" do
    test "the engine's child spec carries the 10s shutdown budget" do
      # The 5s default can kill the process mid-write, so the save-on-shutdown
      # guarantee depends on this. It lives on the module rather than only on the
      # Application child spec so every caller - including start_supervised!/1
      # in these tests - gets the same budget as production.
      assert CityEngine.child_spec([])[:shutdown] == 10_000
    end

    test "checkpoints the post-tick map at the configured tick interval" do
      Application.put_env(:armchair_metropolist, :checkpoint_every_ticks, 2)
      StubSnapshotRepository.set_initial({:ok, {0, starved_city()}})
      start_supervised!(CityEngine)

      broadcast_tick(1)
      assert {:ok, %{city_map: %{tick: 1}}} = CityEngine.snapshot()
      assert StubSnapshotRepository.saves() == [], "tick 1 is not a checkpoint"

      broadcast_tick(2)
      assert {:ok, %{city_map: at_tick_2}} = CityEngine.snapshot()
      assert [{2, saved}] = StubSnapshotRepository.saves()

      # Pin *which* version of the map was written. Saving the pre-tick map
      # instead would store the tick-1 state, which is a different map with
      # different node health even though both would satisfy `saved.tick == 2`
      # under a weaker assertion.
      assert saved == at_tick_2
      assert saved.tick == 2
      assert CityMap.get_node(saved, 0, 0) == CityMap.get_node(at_tick_2, 0, 0)
      assert CityMap.get_node(saved, 0, 0).health < 100.0

      broadcast_tick(3)
      assert {:ok, %{city_map: %{tick: 3}}} = CityEngine.snapshot()
      assert [{2, ^saved}] = StubSnapshotRepository.saves(), "tick 3 is not a checkpoint"
    end

    test "treats a non-positive checkpoint interval as checkpointing disabled" do
      # rem(tick, 0) raises inside handle_info/2, which would put the engine in
      # a restart loop on every tick rather than failing at boot.
      Application.put_env(:armchair_metropolist, :checkpoint_every_ticks, 0)
      StubSnapshotRepository.set_initial({:error, :not_found})
      pid = start_supervised!(CityEngine)

      broadcast_tick(1)
      broadcast_tick(2)

      assert {:ok, %{city_map: %{tick: 2}}} = CityEngine.snapshot()
      assert Process.whereis(CityEngine) == pid, "the engine must not have crashed and restarted"
      assert StubSnapshotRepository.saves() == []
    end

    test "terminate/2 persists the city map on a graceful supervisor shutdown" do
      StubSnapshotRepository.set_initial({:error, :not_found})
      pid = start_supervised!(CityEngine)
      {:ok, _node} = CityEngine.place(1, 1, :power_plant)

      assert StubSnapshotRepository.saves() == []

      ref = Process.monitor(pid)
      stop_supervised!(CityEngine)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000

      assert [{0, saved} | _] = StubSnapshotRepository.saves()
      assert CityMap.occupied?(saved, 1, 1)
    end

    test "terminate/2 persists the post-tick state" do
      StubSnapshotRepository.set_initial({:ok, {0, starved_city()}})
      pid = start_supervised!(CityEngine)

      broadcast_tick(1)
      assert {:ok, %{city_map: %{tick: 1}}} = CityEngine.snapshot()

      ref = Process.monitor(pid)
      stop_supervised!(CityEngine)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000

      assert [{1, saved} | _] = StubSnapshotRepository.saves()
      assert saved.tick == 1
    end
  end

  describe "critical deficit notifications" do
    test "notifies once when the city first enters a critical deficit" do
      # Seed a city that cannot meet demand: many consumers, no producers.
      city =
        Enum.reduce(0..9, CityMap.new(40, 30), fn x, acc ->
          CityMap.put_node(acc, Node.new(x, 0, :commercial))
        end)

      StubSnapshotRepository.set_initial({:ok, {0, city}})
      start_supervised!(CityEngine)

      Phoenix.PubSub.broadcast(ArmchairMetropolist.PubSub, "city_tick", {:tick, 1})
      assert_receive {:notified, _title, _body}, 1_000

      # Still in deficit on the next tick, but must not notify again.
      Phoenix.PubSub.broadcast(ArmchairMetropolist.PubSub, "city_tick", {:tick, 2})
      refute_receive {:notified, _, _}, 300
    end

    test "names the resources in deficit, worst first" do
      StubSnapshotRepository.set_initial({:ok, {0, starved_city()}})
      start_supervised!(CityEngine)

      broadcast_tick(1)

      assert_receive {:notified, title, body}, 1_000
      assert is_binary(title)
      assert body =~ "power at 18% of demand"

      # Ten commercial nodes against baseline capacity alone: power 40/220,
      # waste 40/140, traffic 40/90, water 40/80. The order is the severity
      # signal the operator reads first, so it is pinned, not incidental.
      named =
        body
        |> String.split(", ")
        |> Enum.map(fn part -> part |> String.split(" ", parts: 2) |> hd() end)

      assert named == ["power", "waste", "traffic", "water"]
    end

    test "does not notify a city that is meeting demand" do
      StubSnapshotRepository.set_initial({:ok, {0, CityMap.new(40, 30)}})
      start_supervised!(CityEngine)

      broadcast_tick(1)
      assert {:ok, %{metrics: metrics}} = CityEngine.snapshot()
      assert Enum.all?(metrics.resources, fn {_r, stats} -> stats.satisfaction == 1.0 end)

      refute_receive {:notified, _, _}, 300
    end

    test "re-arms once satisfaction recovers" do
      StubSnapshotRepository.set_initial({:ok, {0, starved_city()}})
      start_supervised!(CityEngine)

      broadcast_tick(1)
      assert_receive {:notified, _, _}, 1_000

      # Demolishing every consumer removes all demand, so satisfaction returns
      # to 1.0 and the notification must re-arm.
      Enum.each(0..9, fn x -> {:ok, _id} = CityEngine.demolish(x, 0) end)
      broadcast_tick(2)
      assert {:ok, %{city_map: %{tick: 2}}} = CityEngine.snapshot()
      refute_receive {:notified, _, _}, 200

      Enum.each(0..9, fn x -> {:ok, _node} = CityEngine.place(x, 0, :commercial) end)
      broadcast_tick(3)
      assert_receive {:notified, _, _}, 1_000
    end
  end

  # Ten commercial nodes and no producers: baseline capacity cannot cover the
  # demand, so every resource sits below full satisfaction.
  defp starved_city do
    Enum.reduce(0..9, CityMap.new(40, 30), fn x, acc ->
      CityMap.put_node(acc, Node.new(x, 0, :commercial))
    end)
  end

  defp broadcast_tick(n) do
    :ok = Phoenix.PubSub.broadcast(ArmchairMetropolist.PubSub, @tick_topic, {:tick, n})
  end

  # No matching unsubscribe: the subscription is owned by the test process and
  # PubSub drops it when that process exits at the end of the test.
  defp subscribe_simulation do
    :ok = Phoenix.PubSub.subscribe(ArmchairMetropolist.PubSub, @simulation_topic)
  end
end
