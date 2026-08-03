defmodule ArmchairMetropolist.FailingSnapshotRepository do
  @moduledoc """
  A repository whose every save fails, each in a different way.

  Three separate failure modes because the engine has to survive all three: the
  port's declared `{:error, term()}`, an adapter that raises anyway, and one that
  exits. Defined here rather than in test/support because nothing outside this
  file needs them.
  """
  @behaviour ArmchairMetropolist.Domain.Ports.SnapshotRepository

  @impl true
  def load(_city_id), do: {:error, :not_found}

  @impl true
  def save(_city_id, _tick, _city_map) do
    case Application.get_env(:armchair_metropolist, :failing_repository_mode, :error_tuple) do
      :error_tuple -> {:error, :disk_full}
      :raise -> raise File.Error, reason: :eacces, action: "write to", path: "snapshot.bin"
      :exit -> exit(:timeout)
    end
  end
end

defmodule ArmchairMetropolist.Infrastructure.Simulation.CityEngineTest do
  @moduledoc """
  Engine lifecycle tests.

  `async: false` throughout: these mutate application env (to inject the stub
  adapters), which is process-global. The engine itself no longer needs it — each
  test gets a unique city id and therefore its own registered process — but the
  application-env overrides in `setup` still are.

  Ticks are injected by broadcasting on `"city_tick"` rather than by waiting on
  the real clock, so nothing here depends on timers. `CityEngine.snapshot/1` is
  used as a synchronisation barrier — it is a `GenServer.call`, so when it
  returns, every tick broadcast before it has already been handled.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ArmchairMetropolist.Domain.Entities.CityMap
  alias ArmchairMetropolist.Domain.Entities.Node
  alias ArmchairMetropolist.FailingSnapshotRepository
  alias ArmchairMetropolist.Infrastructure.Simulation.CityEngine
  alias ArmchairMetropolist.Infrastructure.Simulation.CityRegistry
  alias ArmchairMetropolist.SlowSnapshotRepository
  alias ArmchairMetropolist.StubNotifier
  alias ArmchairMetropolist.StubSnapshotRepository

  @tick_topic "city_tick"

  @overridden_keys [
    :snapshot_repository,
    :notifier,
    :notifier_test_pid,
    :checkpoint_every_ticks,
    :failing_repository_mode
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

    city_id = "test-#{System.unique_integer([:positive])}"
    {:ok, city_id: city_id}
  end

  describe "hydration" do
    test "hydrates from the latest stored snapshot", %{city_id: city_id} do
      city = CityMap.put_node(CityMap.new(40, 30), Node.new(1, 1, :power_plant))
      stored = %{city | tick: 7}

      StubSnapshotRepository.set_initial({:ok, {7, stored}})
      start_supervised!({CityEngine, city_id: city_id})

      assert {:ok, %{city_map: city_map, metrics: metrics}} = CityEngine.snapshot(city_id)
      assert city_map == stored
      assert city_map.tick == 7
      assert metrics.tick == 7
      assert metrics.node_count == 1
    end

    test "reports resource figures before the first tick has run", %{city_id: city_id} do
      # Regression: the engine used to hydrate with SimulationMetrics.build(map, %{}),
      # so `resources` was empty until a tick landed and a LiveView mounting in that
      # window had no supply/demand to render. Infrastructure cannot compute these
      # itself (boundary bars Domain.Services), hence UseCases.SummarizeCity.
      StubSnapshotRepository.set_initial({:ok, {3, CityMap.new(40, 30)}})
      start_supervised!({CityEngine, city_id: city_id})

      assert {:ok, %{metrics: metrics}} = CityEngine.snapshot(city_id)

      assert Enum.sort(Map.keys(metrics.resources)) == [
               :labour,
               :money,
               :power,
               :traffic,
               :waste,
               :water
             ],
             "metrics must carry every resource at mount, not an empty map"

      assert metrics.resources.power.satisfaction == 1.0
    end

    test "falls back to an empty configured grid when nothing is stored", %{city_id: city_id} do
      StubSnapshotRepository.set_initial({:error, :not_found})
      start_supervised!({CityEngine, city_id: city_id})

      assert {:ok, %{city_map: city_map, metrics: metrics}} = CityEngine.snapshot(city_id)
      assert city_map.width == 40
      assert city_map.height == 30
      assert city_map.tick == 0
      assert CityMap.nodes(city_map) == []
      assert metrics.node_count == 0
    end

    @tag :capture_log
    test "falls back to an empty grid when the repository errors", %{city_id: city_id} do
      StubSnapshotRepository.set_initial({:error, :checksum_mismatch})
      start_supervised!({CityEngine, city_id: city_id})

      assert {:ok, %{city_map: city_map}} = CityEngine.snapshot(city_id)
      assert CityMap.nodes(city_map) == []
    end

    # Every stored city predates `money`. A term encoded without it decodes under
    # :safe as a struct carrying only the old keys, and reading .money then raises
    # KeyError *after* a successful load — crash-looping this supervised process
    # rather than falling back to a new city. Nothing else in the suite constructs a
    # CityMap from a term missing a field, so without this the regression is silent.
    test "a snapshot stored before the money field loads with the default balance" do
      legacy = %{
        __struct__: ArmchairMetropolist.Domain.Entities.CityMap,
        width: 40,
        height: 30,
        tick: 7,
        nodes: %{"0:0" => Node.new(0, 0, :park)}
      }

      round_tripped = :erlang.binary_to_term(:erlang.term_to_binary(legacy), [:safe])
      loaded = CityEngine.normalize_city_map(round_tripped)

      assert loaded.money == 500.0
      assert loaded.tick == 7
      assert map_size(loaded.nodes) == 1
    end

    test "start_link/1 returns before a slow repository has answered", %{city_id: city_id} do
      # Hydration must happen in handle_continue/2, not init/1: a snapshot read
      # inside init/1 blocks the caller, which at boot is the whole supervision
      # tree. This adapter stalls for 400ms, so start_link/1 taking that long
      # is the signature of the read having moved into init/1.
      Application.put_env(:armchair_metropolist, :snapshot_repository, SlowSnapshotRepository)
      StubSnapshotRepository.set_initial({:error, :not_found})

      {micros, _pid} = :timer.tc(fn -> start_supervised!({CityEngine, city_id: city_id}) end)
      elapsed_ms = div(micros, 1000)

      assert elapsed_ms < 200,
             "start_link must not block on hydration - hydrate in handle_continue, " <>
               "not init/1 (took #{elapsed_ms}ms, repository stalls for " <>
               "#{SlowSnapshotRepository.delay_ms()}ms)"

      # ...and the hydration it deferred still completes.
      assert {:ok, %{city_map: city_map}} = CityEngine.snapshot(city_id)
      assert city_map.width == 40
      assert city_map.height == 30
    end
  end

  describe "ticks" do
    test "broadcasts a delta and metrics for every tick on \"city_tick\"", %{city_id: city_id} do
      StubSnapshotRepository.set_initial({:ok, {0, starved_city()}})
      start_supervised!({CityEngine, city_id: city_id})
      subscribe_simulation(city_id)

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

    test "advances city_map.tick and ignores the clock's counter", %{city_id: city_id} do
      StubSnapshotRepository.set_initial({:ok, {0, CityMap.new(40, 30)}})
      start_supervised!({CityEngine, city_id: city_id})

      # Clock pulse numbers are diagnostic only: an out-of-order or restarted
      # clock must not move the authoritative simulation tick.
      broadcast_tick(99)
      broadcast_tick(1)

      assert {:ok, %{city_map: city_map, metrics: metrics}} = CityEngine.snapshot(city_id)
      assert city_map.tick == 2
      assert metrics.tick == 2
    end
  end

  describe "infrastructure commands" do
    setup %{city_id: city_id} do
      StubSnapshotRepository.set_initial({:error, :not_found})
      start_supervised!({CityEngine, city_id: city_id})
      :ok
    end

    test "place/3 adds the node and broadcasts it", %{city_id: city_id} do
      subscribe_simulation(city_id)

      assert {:ok, %Node{} = node} = CityEngine.place(city_id, 3, 4, :power_plant)
      assert node.id == Node.id(3, 4)
      assert node.type == :power_plant
      assert_receive {:city_node_placed, ^node}, 1_000

      assert {:ok, %{city_map: city_map}} = CityEngine.snapshot(city_id)
      assert CityMap.get_node(city_map, 3, 4) == node
    end

    test "demolish/2 removes the node and broadcasts its id", %{city_id: city_id} do
      {:ok, node} = CityEngine.place(city_id, 3, 4, :power_plant)
      subscribe_simulation(city_id)

      assert {:ok, id} = CityEngine.demolish(city_id, 3, 4)
      assert id == node.id
      assert_receive {:city_node_removed, ^id}, 1_000

      assert {:ok, %{city_map: city_map}} = CityEngine.snapshot(city_id)
      refute CityMap.occupied?(city_map, 3, 4)
    end

    test "metrics track a command immediately rather than lagging a tick", %{city_id: city_id} do
      # Regression: metrics were only refreshed on tick, so between a place and the
      # next tick `snapshot/1` reported a node_count that disagreed with city_map.
      assert {:ok, %{metrics: before}} = CityEngine.snapshot(city_id)
      assert before.node_count == 0

      {:ok, _node} = CityEngine.place(city_id, 3, 4, :residential)

      assert {:ok, %{city_map: city_map, metrics: metrics}} = CityEngine.snapshot(city_id)

      assert metrics.node_count == map_size(city_map.nodes),
             "metrics must agree with city_map without waiting for a tick"

      assert metrics.node_count == 1
      assert metrics.resources.power.demanded > 0.0

      {:ok, _id} = CityEngine.demolish(city_id, 3, 4)

      assert {:ok, %{city_map: city_map, metrics: metrics}} = CityEngine.snapshot(city_id)
      assert metrics.node_count == map_size(city_map.nodes)
      assert metrics.node_count == 0
    end

    test "place/3 on an occupied cell returns an error and broadcasts nothing", %{
      city_id: city_id
    } do
      {:ok, _node} = CityEngine.place(city_id, 3, 4, :power_plant)
      subscribe_simulation(city_id)

      assert {:error, :occupied} = CityEngine.place(city_id, 3, 4, :commercial)
      refute_receive {:city_node_placed, _}, 200

      assert {:ok, %{city_map: city_map}} = CityEngine.snapshot(city_id)
      assert CityMap.get_node(city_map, 3, 4).type == :power_plant
    end

    test "rejects out-of-bounds coordinates and unknown types", %{city_id: city_id} do
      subscribe_simulation(city_id)

      assert {:error, :out_of_bounds} = CityEngine.place(city_id, 40, 0, :park)
      assert {:error, :unknown_type} = CityEngine.place(city_id, 1, 1, :space_elevator)
      refute_receive {:city_node_placed, _}, 200
    end

    test "demolish/2 on an empty cell returns an error and broadcasts nothing", %{
      city_id: city_id
    } do
      subscribe_simulation(city_id)

      assert {:error, :empty} = CityEngine.demolish(city_id, 5, 5)
      refute_receive {:city_node_removed, _}, 200
    end
  end

  describe "metrics broadcasts on commands" do
    setup %{city_id: city_id} do
      StubSnapshotRepository.set_initial({:error, :not_found})
      start_supervised!({CityEngine, city_id: city_id})
      :ok
    end

    test "placing broadcasts fresh metrics, not just the node", %{city_id: city_id} do
      Phoenix.PubSub.subscribe(ArmchairMetropolist.PubSub, CityEngine.topic(city_id))

      assert {:ok, _node} = CityEngine.place(city_id, 0, 0, :power_plant)

      assert_receive {:city_node_placed, _node}

      assert_receive {:city_metrics, metrics}
      assert metrics.node_count == 1

      assert metrics.by_type.power_plant.count == 1,
             "a subscriber must see the new node reflected in metrics immediately, " <>
               "not only after the next tick"
    end

    test "demolishing broadcasts fresh metrics, not just the id", %{city_id: city_id} do
      assert {:ok, _node} = CityEngine.place(city_id, 0, 0, :power_plant)

      Phoenix.PubSub.subscribe(ArmchairMetropolist.PubSub, CityEngine.topic(city_id))
      assert {:ok, "0:0"} = CityEngine.demolish(city_id, 0, 0)

      assert_receive {:city_node_removed, "0:0"}

      assert_receive {:city_metrics, metrics}
      assert metrics.node_count == 0
      assert metrics.by_type.power_plant.count == 0
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

    test "checkpoints the post-tick map at the configured tick interval", %{city_id: city_id} do
      Application.put_env(:armchair_metropolist, :checkpoint_every_ticks, 2)
      StubSnapshotRepository.set_initial({:ok, {0, starved_city()}})
      start_supervised!({CityEngine, city_id: city_id})

      broadcast_tick(1)
      assert {:ok, %{city_map: %{tick: 1}}} = CityEngine.snapshot(city_id)
      assert StubSnapshotRepository.saves() == [], "tick 1 is not a checkpoint"

      broadcast_tick(2)
      assert {:ok, %{city_map: at_tick_2}} = CityEngine.snapshot(city_id)
      assert [{^city_id, 2, saved}] = StubSnapshotRepository.saves()

      # Pin *which* version of the map was written. Saving the pre-tick map
      # instead would store the tick-1 state, which is a different map with
      # different node health even though both would satisfy `saved.tick == 2`
      # under a weaker assertion.
      assert saved == at_tick_2
      assert saved.tick == 2
      assert CityMap.get_node(saved, 0, 0) == CityMap.get_node(at_tick_2, 0, 0)
      assert CityMap.get_node(saved, 0, 0).health < 100.0

      broadcast_tick(3)
      assert {:ok, %{city_map: %{tick: 3}}} = CityEngine.snapshot(city_id)

      assert [{^city_id, 2, ^saved}] = StubSnapshotRepository.saves(),
             "tick 3 is not a checkpoint"
    end

    test "treats a non-positive checkpoint interval as checkpointing disabled", %{
      city_id: city_id
    } do
      # rem(tick, 0) raises inside handle_info/2, which would put the engine in
      # a restart loop on every tick rather than failing at boot.
      Application.put_env(:armchair_metropolist, :checkpoint_every_ticks, 0)
      StubSnapshotRepository.set_initial({:error, :not_found})
      pid = start_supervised!({CityEngine, city_id: city_id})

      broadcast_tick(1)
      broadcast_tick(2)

      assert {:ok, %{city_map: %{tick: 2}}} = CityEngine.snapshot(city_id)

      assert CityRegistry.whereis(city_id) == pid,
             "the engine must not have crashed and restarted"

      assert StubSnapshotRepository.saves() == []
    end

    test "terminate/2 persists the city map on a graceful supervisor shutdown", %{
      city_id: city_id
    } do
      StubSnapshotRepository.set_initial({:error, :not_found})
      pid = start_supervised!({CityEngine, city_id: city_id})
      {:ok, _node} = CityEngine.place(city_id, 1, 1, :power_plant)

      assert StubSnapshotRepository.saves() == []

      ref = Process.monitor(pid)
      stop_supervised!(CityEngine)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000

      assert [{^city_id, 0, saved} | _] = StubSnapshotRepository.saves()
      assert CityMap.occupied?(saved, 1, 1)
    end

    test "terminate/2 persists the post-tick state", %{city_id: city_id} do
      StubSnapshotRepository.set_initial({:ok, {0, starved_city()}})
      pid = start_supervised!({CityEngine, city_id: city_id})

      broadcast_tick(1)
      assert {:ok, %{city_map: %{tick: 1}}} = CityEngine.snapshot(city_id)

      ref = Process.monitor(pid)
      stop_supervised!(CityEngine)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000

      assert [{^city_id, 1, saved} | _] = StubSnapshotRepository.saves()
      assert saved.tick == 1
    end

    test "warns rather than failing when the adapter refuses a stale save", %{city_id: city_id} do
      # Without this override tick 1 is not a checkpoint (the default interval is
      # 50), and the save the assertions below depend on would never happen.
      Application.put_env(:armchair_metropolist, :checkpoint_every_ticks, 1)
      StubSnapshotRepository.set_initial({:ok, {3, CityMap.new(40, 30)}})
      start_supervised!({CityEngine, city_id: city_id})
      StubSnapshotRepository.refuse_saves_as_stale(99)

      log =
        capture_log(fn ->
          {:ok, _node} = CityEngine.place(city_id, 1, 1, :power_plant)
          Phoenix.PubSub.broadcast(ArmchairMetropolist.PubSub, @tick_topic, {:tick, 1})
          # Let the engine handle the tick, whose checkpoint attempts the save.
          {:ok, _} = CityEngine.snapshot(city_id)
        end)

      assert log =~ "declined to persist"
      assert log =~ "tick 99"
      refute log =~ "failed to persist"
    end
  end

  describe "a repository that cannot save" do
    # The failure the engine must absorb rather than propagate. A raise out of a
    # checkpoint kills the engine, the supervisor restarts it, and hydration rolls
    # the city back to the previous checkpoint — so a permanently unwritable
    # snapshot directory silently discards `checkpoint_every_ticks` worth of the
    # player's work over and over, without ever tripping `max_restarts`, because
    # the restarts are a whole checkpoint interval apart.
    setup do
      Application.put_env(:armchair_metropolist, :snapshot_repository, FailingSnapshotRepository)
      Application.put_env(:armchair_metropolist, :checkpoint_every_ticks, 1)
      :ok
    end

    for {mode, description} <- [
          error_tuple: "returns {:error, reason}",
          raise: "raises",
          exit: "exits"
        ] do
      test "a checkpoint against a repository that #{description} keeps the engine and its state",
           %{city_id: city_id} do
        Application.put_env(:armchair_metropolist, :failing_repository_mode, unquote(mode))

        pid = start_supervised!({CityEngine, city_id: city_id})
        {:ok, node} = CityEngine.place(city_id, 1, 1, :power_plant)

        # The shutdown is inside the capture too: terminate/2 saves as well, and
        # its failure would otherwise leak past the test into `mix check`'s output.
        log =
          capture_log(fn ->
            broadcast_tick(1)
            assert {:ok, %{city_map: %{tick: 1}}} = CityEngine.snapshot(city_id)
            broadcast_tick(2)
            assert {:ok, %{city_map: %{tick: 2}}} = CityEngine.snapshot(city_id)

            assert CityRegistry.whereis(city_id) == pid,
                   "the engine must not have crashed and restarted"

            # A restart would have rehydrated an empty city at tick 0, so this is
            # the assertion that the ticks since the last checkpoint survived.
            assert {:ok, %{city_map: city_map}} = CityEngine.snapshot(city_id)
            assert city_map.tick == 2
            assert CityMap.get_node(city_map, 1, 1).id == node.id

            stop_supervised!(CityEngine)
          end)

        assert log =~ "failed to persist city snapshot at tick 1"
        assert log =~ "failed to persist city snapshot at tick 2"
      end
    end

    test "the error reason reaches the log", %{city_id: city_id} do
      Application.put_env(:armchair_metropolist, :failing_repository_mode, :error_tuple)
      start_supervised!({CityEngine, city_id: city_id})

      log =
        capture_log(fn ->
          broadcast_tick(1)
          assert {:ok, _snapshot} = CityEngine.snapshot(city_id)
          stop_supervised!(CityEngine)
        end)

      assert log =~ ":disk_full"
    end

    test "terminate/2 still completes shutdown when the repository raises", %{city_id: city_id} do
      Application.put_env(:armchair_metropolist, :failing_repository_mode, :raise)

      pid = start_supervised!({CityEngine, city_id: city_id})
      {:ok, _node} = CityEngine.place(city_id, 1, 1, :power_plant)
      ref = Process.monitor(pid)

      log =
        capture_log(fn ->
          stop_supervised!(CityEngine)
          assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
        end)

      assert log =~ "failed to persist city snapshot at tick 0"
      refute Process.alive?(pid)
    end
  end

  describe "critical deficit notifications" do
    test "notifies once when the city first enters a critical deficit", %{city_id: city_id} do
      # Seed a city that cannot meet demand: many consumers, no producers.
      city =
        Enum.reduce(0..9, CityMap.new(40, 30), fn x, acc ->
          CityMap.put_node(acc, Node.new(x, 0, :commercial))
        end)

      StubSnapshotRepository.set_initial({:ok, {0, city}})
      start_supervised!({CityEngine, city_id: city_id})

      Phoenix.PubSub.broadcast(ArmchairMetropolist.PubSub, "city_tick", {:tick, 1})
      assert_receive {:notified, _title, _body}, 1_000

      # Still in deficit on the next tick, but must not notify again.
      Phoenix.PubSub.broadcast(ArmchairMetropolist.PubSub, "city_tick", {:tick, 2})
      refute_receive {:notified, _, _}, 300
    end

    test "names the resources in deficit, worst first", %{city_id: city_id} do
      StubSnapshotRepository.set_initial({:ok, {0, starved_city()}})
      start_supervised!({CityEngine, city_id: city_id})

      broadcast_tick(1)

      assert_receive {:notified, title, body}, 1_000
      assert is_binary(title)
      assert body =~ "power at 18% of demand"

      # Ten commercial nodes against baseline capacity alone: labour 0/80 (no
      # housing at all, so 0%), power 40/220, waste 40/140, traffic 40/90,
      # water 40/80. The order is the severity signal the operator reads
      # first, so it is pinned, not incidental.
      named =
        body
        |> String.split(", ")
        |> Enum.map(fn part -> part |> String.split(" ", parts: 2) |> hd() end)

      assert named == ["labour", "power", "waste", "traffic", "water"]
    end

    test "does not notify a city that is meeting demand", %{city_id: city_id} do
      StubSnapshotRepository.set_initial({:ok, {0, CityMap.new(40, 30)}})
      start_supervised!({CityEngine, city_id: city_id})

      broadcast_tick(1)
      assert {:ok, %{metrics: metrics}} = CityEngine.snapshot(city_id)
      assert Enum.all?(metrics.resources, fn {_r, stats} -> stats.satisfaction == 1.0 end)

      refute_receive {:notified, _, _}, 300
    end

    test "re-arms once satisfaction recovers", %{city_id: city_id} do
      StubSnapshotRepository.set_initial({:ok, {0, starved_city()}})
      start_supervised!({CityEngine, city_id: city_id})

      broadcast_tick(1)
      assert_receive {:notified, _, _}, 1_000

      # Demolishing every consumer removes all demand, so satisfaction returns
      # to 1.0 and the notification must re-arm.
      Enum.each(0..9, fn x -> {:ok, _id} = CityEngine.demolish(city_id, x, 0) end)
      broadcast_tick(2)
      assert {:ok, %{city_map: %{tick: 2}}} = CityEngine.snapshot(city_id)
      refute_receive {:notified, _, _}, 200

      Enum.each(0..9, fn x -> {:ok, _node} = CityEngine.place(city_id, x, 0, :commercial) end)
      broadcast_tick(3)
      assert_receive {:notified, _, _}, 1_000
    end
  end

  describe "isolation between cities" do
    test "one city's snapshot does not see another's nodes" do
      a = "iso-a-#{System.unique_integer([:positive])}"
      b = "iso-b-#{System.unique_integer([:positive])}"
      start_supervised!({CityEngine, city_id: a}, id: :engine_a)
      start_supervised!({CityEngine, city_id: b}, id: :engine_b)

      {:ok, _node} = CityEngine.place(a, 3, 4, :power_plant)

      assert {:ok, %{city_map: map_a}} = CityEngine.snapshot(a)
      assert {:ok, %{city_map: map_b}} = CityEngine.snapshot(b)
      assert map_size(map_a.nodes) == 1
      assert map_size(map_b.nodes) == 0
    end

    test "a delta is broadcast to its own city's topic and not another's" do
      a = "iso-a-#{System.unique_integer([:positive])}"
      b = "iso-b-#{System.unique_integer([:positive])}"
      start_supervised!({CityEngine, city_id: a}, id: :engine_a)
      start_supervised!({CityEngine, city_id: b}, id: :engine_b)

      :ok = Phoenix.PubSub.subscribe(ArmchairMetropolist.PubSub, CityEngine.topic(a))
      :ok = Phoenix.PubSub.subscribe(ArmchairMetropolist.PubSub, CityEngine.topic(b))

      {:ok, _node} = CityEngine.place(a, 3, 4, :power_plant)

      # Positive first: without this the refute below is vacuous.
      assert_receive {:city_node_placed, %Node{x: 3, y: 4}}
      # And nothing further, which is what proves the topics are distinct rather
      # than one shared topic delivering to both subscriptions.
      refute_receive {:city_node_placed, _}, 200
    end
  end

  describe "freezing when the last viewer leaves" do
    setup %{city_id: city_id} do
      Application.put_env(:armchair_metropolist, :engine_linger_ms, 50)

      # These tests reach the engine through CityRegistry.ensure_started/1, the same
      # start-on-demand path production uses, rather than start_supervised!/1 - so
      # nothing tears it down automatically the way every other test in this file
      # gets for free. An engine still alive when the test ends stays subscribed to
      # "city_tick" and keeps answering CityEngine calls, so a later test's tick
      # broadcast or config override could make it checkpoint into that later test's
      # StubSnapshotRepository. Unconditional here (`whereis` is nil for the tests
      # whose engine already stopped itself) rather than only for the ones that leak
      # by design.
      #
      # DynamicSupervisor.terminate_child/2, not Process.exit/2: the engine's child
      # spec is `restart: :transient`, so an exit this test merely *causes* (rather
      # than asks the supervisor for) reads as abnormal and gets restarted right
      # back - and the restart, hydrating after this test's on_exit has already torn
      # down its stub config, is what took the whole registry supervisor down under
      # repeated failures during this fix's development. terminate_child/2 discards
      # the child spec first, so no restart follows no matter how termination looks.
      #
      # capture_log: this on_exit runs after `start_supervised!(StubSnapshotRepository)`
      # has already been torn down (ExUnit stops supervised processes before running
      # on_exit callbacks, regardless of registration order), so terminate/2's own save
      # always fails here with :noproc. That failure is exactly what save/2 already
      # exists to absorb - see the "repository that cannot save" tests below - so this
      # only silences an expected, harmless log line rather than hiding a real one.
      on_exit(fn ->
        case CityRegistry.whereis(city_id) do
          nil ->
            :ok

          pid ->
            capture_log(fn -> DynamicSupervisor.terminate_child(CityRegistry.Supervisor, pid) end)
        end
      end)

      :ok
    end

    test "saves and stops after the linger once the last viewer goes", %{city_id: city_id} do
      {:ok, pid} = CityRegistry.ensure_started(city_id)
      viewer = spawn(fn -> Process.sleep(:infinity) end)
      :ok = CityEngine.attach(city_id, viewer)
      ref = Process.monitor(pid)

      Process.exit(viewer, :kill)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000

      # Our monitor and CityRegistry's own are independent, so receiving our :DOWN
      # is no guarantee the registry has processed its own yet - the same race
      # CityEngine.call/3's retry absorbs in production. Polling rather than
      # asserting immediately is what makes this check the behaviour instead of
      # this scheduler's luck; confirmed flaky (~1 in 5) without it.
      assert wait_until(fn -> CityRegistry.whereis(city_id) == nil end)
    end

    test "a viewer arriving during the linger cancels the stop", %{city_id: city_id} do
      {:ok, pid} = CityRegistry.ensure_started(city_id)
      first = spawn(fn -> Process.sleep(:infinity) end)
      :ok = CityEngine.attach(city_id, first)
      ref = Process.monitor(pid)

      Process.exit(first, :kill)
      # Inside the 50ms linger.
      second = spawn(fn -> Process.sleep(:infinity) end)
      :ok = CityEngine.attach(city_id, second)

      # handle_info(:linger_expired, ...) re-checks the viewer set before stopping,
      # so the engine surviving 300ms below is true regardless of whether the timer
      # was actually cancelled - a present second viewer makes it survive either
      # way, which is exactly the case a naive "just check it's still alive"
      # assertion gets wrong (confirmed by mutation: deleting the cancel_linger/1
      # call left every assertion below still green). What the cancel actually
      # changes is the `linger` field itself: cancel_linger/1 always resets it to
      # nil, so if the second attach left the *original* timer running instead,
      # this reads it back non-nil.
      assert :sys.get_state(pid).linger == nil

      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 300
      assert CityRegistry.whereis(city_id) == pid
    end

    test "a frozen city reloads its state when next addressed", %{city_id: city_id} do
      StubSnapshotRepository.echo_saves()
      {:ok, _pid} = CityRegistry.ensure_started(city_id)
      viewer = spawn(fn -> Process.sleep(:infinity) end)
      :ok = CityEngine.attach(city_id, viewer)
      {:ok, _node} = CityEngine.place(city_id, 3, 4, :power_plant)

      Process.exit(viewer, :kill)
      assert wait_until(fn -> CityRegistry.whereis(city_id) == nil end)

      # The stub returns whatever `set_initial/1` holds, so this asserts the save
      # happened by asserting the engine wrote before it stopped.
      assert {:ok, %{city_map: reloaded}} = CityEngine.snapshot(city_id)
      assert map_size(reloaded.nodes) == 1
    end
  end

  # Ten commercial nodes and no producers: baseline capacity cannot cover the
  # demand, so every resource sits below full satisfaction.
  defp starved_city do
    Enum.reduce(0..9, CityMap.new(40, 30), fn x, acc ->
      CityMap.put_node(acc, Node.new(x, 0, :commercial))
    end)
  end

  # Polls `fun` until it returns truthy or 500ms have passed, returning the last
  # result. For asserting an engine has stopped: whereis/1 depends on
  # CityRegistry's own monitor of the engine, a race against any other monitor
  # (including a test's) on the same process, so nothing guarantees it has already
  # caught up the instant another observer sees the engine gone.
  defp wait_until(fun, attempts \\ 50) do
    case {fun.(), attempts} do
      {result, _} when result != false and result != nil -> result
      {result, 0} -> result
      {_, attempts} -> Process.sleep(10) && wait_until(fun, attempts - 1)
    end
  end

  defp broadcast_tick(n) do
    :ok = Phoenix.PubSub.broadcast(ArmchairMetropolist.PubSub, @tick_topic, {:tick, n})
  end

  # No matching unsubscribe: the subscription is owned by the test process and
  # PubSub drops it when that process exits at the end of the test.
  defp subscribe_simulation(city_id) do
    :ok = Phoenix.PubSub.subscribe(ArmchairMetropolist.PubSub, CityEngine.topic(city_id))
  end
end
