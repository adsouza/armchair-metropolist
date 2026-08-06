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

  # Wide enough that a spawn + GenServer.call round trip landing inside it is not a
  # race even on a loaded CI runner, and wide enough to give the orphaned-timer test
  # below a comfortable gap between the deadline a leaked, uncancelled timer would
  # fire at and the deadline the correct, fresh one actually fires at. Shared between
  # the two tests that need it rather than each picking its own value.
  @wide_linger_ms 400

  @overridden_keys [
    :snapshot_repository,
    :notifier,
    :notifier_test_pid,
    :checkpoint_every_ticks,
    :failing_repository_mode,
    # Every engine now arms a linger on hydrate (handle_continue/2), not only ones a
    # viewer later leaves, so a short value here is no longer inert for tests that
    # never call attach/2 - unlike before, it now determines when *any* engine in
    # this file stops itself. Without restoring it, the "freezing" describe's
    # override leaked into every test that ran afterward in seed order, which
    # intermittently killed unrelated engines mid-test.
    :engine_linger_ms,
    # The pre-attach counterpart of the key above - handle_continue(:hydrate, ...)
    # arms this one, not :engine_linger_ms, before any viewer has ever attached.
    # This list has already drifted three times in this branch; adding a key here
    # whenever a new one governs when an engine in this suite stops itself is what
    # stops a fourth.
    :engine_unattached_linger_ms
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

      assert loaded.money == CityMap.opening_grant()
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

  describe "the treasury gates commands" do
    # No setup starting the engine here, unlike the two describe blocks above: each of
    # these tests seeds a *balance* into the stored snapshot before `start_supervised!`,
    # and the engine owns the money from hydration onwards.

    test "a refused command broadcasts nothing, but an accepted one does", %{city_id: city_id} do
      StubSnapshotRepository.set_initial({:ok, {0, %{CityMap.new(40, 30) | money: 20.0}}})
      start_supervised!({CityEngine, city_id: city_id})
      subscribe_simulation(city_id)

      # Affordable: exactly 20 for a park, leaving zero. Broadcast expected.
      assert {:ok, _node} = CityEngine.place(city_id, 1, 1, :park)
      assert_receive {:city_metrics, _}

      # Now broke. Refused, and silent.
      assert {:error, :insufficient_funds} = CityEngine.place(city_id, 2, 2, :park)
      refute_receive {:city_metrics, _}, 50
    end

    test "metrics broadcast after a place carry the post-debit balance", %{city_id: city_id} do
      # The treasury line must move on the click, not on the next tick. Nothing else
      # catches an engine that computes metrics before debiting.
      StubSnapshotRepository.set_initial({:ok, {0, %{CityMap.new(40, 30) | money: 100.0}}})
      start_supervised!({CityEngine, city_id: city_id})
      subscribe_simulation(city_id)

      {:ok, _node} = CityEngine.place(city_id, 1, 1, :park)

      assert_receive {:city_metrics, metrics}
      assert metrics.money == 80.0
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
      seed_funded_city()
      start_supervised!({CityEngine, city_id: city_id})
      starve(city_id)

      Phoenix.PubSub.broadcast(ArmchairMetropolist.PubSub, "city_tick", {:tick, 1})
      assert_receive {:notified, _title, _body}, 1_000

      # Still in deficit on the next tick, but must not notify again.
      Phoenix.PubSub.broadcast(ArmchairMetropolist.PubSub, "city_tick", {:tick, 2})
      refute_receive {:notified, _, _}, 300
    end

    test "names the resources in deficit, worst first", %{city_id: city_id} do
      seed_funded_city()
      start_supervised!({CityEngine, city_id: city_id})
      starve(city_id)

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
      seed_funded_city()
      start_supervised!({CityEngine, city_id: city_id})
      starve(city_id)

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

    # Every test above lives inside one engine process, which is the one axis this
    # suppression used to be blind to: `critical?` was a field of that process's
    # state, so each new process was armed again while the deficit it guards was
    # still sitting in the snapshot. The desktop log showed the result - three
    # byte-identical "power at 23% of demand, water at 24%..." notifications, one
    # about 3s after each relaunch of an app whose city had not changed in between.
    test "does not notify again when a new engine hydrates a city already in deficit",
         %{city_id: city_id} do
      StubSnapshotRepository.echo_saves()
      seed_funded_city()
      start_supervised!({CityEngine, city_id: city_id})
      starve(city_id)

      broadcast_tick(1)
      assert_receive {:notified, _, _}, 1_000

      # Quitting the app and reopening it: terminate/2 saves the starving city, and a
      # brand-new process hydrates it. Nothing about the deficit is new to the player.
      stop_supervised!(CityEngine)
      start_supervised!({CityEngine, city_id: city_id})
      broadcast_tick(2)

      # Also proves the restart rehydrated the *saved* map rather than an empty one,
      # so the refute below is about suppression and not about a second engine that
      # never saw a deficit at all.
      assert {:ok, %{city_map: %{tick: 2}, metrics: metrics}} = CityEngine.snapshot(city_id)
      assert Enum.any?(metrics.resources, fn {_r, stats} -> stats.satisfaction < 1.0 end)

      refute_receive {:notified, _, _}, 300
    end

    # The other half of hydration: seeding the flag must not make it sticky. Without
    # this, `critical?: true` at hydrate would satisfy every other test in this
    # describe block and silence the notification permanently.
    test "notifies a city that hydrates satisfied and then falls into deficit",
         %{city_id: city_id} do
      # An empty city is satisfied whatever its balance, so seeding the funds `starve/1`
      # needs does not weaken the "hydrates satisfied" half of this test.
      seed_funded_city()
      start_supervised!({CityEngine, city_id: city_id})
      starve(city_id)

      broadcast_tick(1)

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
      # Widened from the describe's 50ms default: this test needs the spawn +
      # GenServer.call round trip below to land inside the linger, and 50ms is not
      # a safe margin for that on a loaded runner - if it lands outside, the timer
      # fires with zero viewers and the engine stops before the next line runs,
      # which would make :sys.get_state(pid) below crash on a dead pid rather than
      # fail cleanly. @wide_linger_ms leaves ample room for the round trip.
      Application.put_env(:armchair_metropolist, :engine_linger_ms, @wide_linger_ms)

      {:ok, pid} = CityRegistry.ensure_started(city_id)
      first = spawn(fn -> Process.sleep(:infinity) end)
      :ok = CityEngine.attach(city_id, first)
      ref = Process.monitor(pid)

      Process.exit(first, :kill)
      # Inside the linger.
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

    test "an orphaned timer left running by a missed cancel does not stop the engine early",
         %{city_id: city_id} do
      # Widened for the same reason as the test above, plus this test's own need for
      # a comfortable gap between two deadlines - see the comments below.
      Application.put_env(:armchair_metropolist, :engine_linger_ms, @wide_linger_ms)

      {:ok, pid} = CityRegistry.ensure_started(city_id)
      first = spawn(fn -> Process.sleep(:infinity) end)
      :ok = CityEngine.attach(city_id, first)
      ref = Process.monitor(pid)

      # T1: armed here, deadline now + @wide_linger_ms.
      Process.exit(first, :kill)

      second = spawn(fn -> Process.sleep(:infinity) end)
      :ok = CityEngine.attach(city_id, second)

      # Well under @wide_linger_ms (400ms), so T1 is still pending - and viewers is
      # non-empty throughout, so even if it fired now it would be a no-op - when
      # `second` is killed below. This is the sequence the two-step "cancels the
      # stop" test above cannot exercise: leave, arrive, leave again - so a second,
      # later timer (T2) gets armed while T1 (uncancelled, under the mutation this
      # guards against) is still alive in the background. 200ms is also what sets
      # the gap between T1's and T2's deadlines below, since T2 is armed fresh from
      # here: the longer this wait, the more margin the window below has on both
      # sides, so it is chosen for that margin, not because the race needs it this
      # long.
      Process.sleep(200)

      # T2: armed here, deadline now + @wide_linger_ms (400ms from this point) - which
      # lands 200ms after T1's original deadline, since T1 was armed 200ms earlier.
      Process.exit(second, :kill)

      # T1's deadline was 200ms before this point. Without the cancel, T1 fires here
      # with an empty viewer set and stops the engine early - 200ms before T2, the
      # correct timer, is due. 300ms below sits at the midpoint: 100ms of margin
      # past where T1 would fire (so its DOWN, if any, is reliably observed inside
      # the window) and 100ms of margin before T2 is due (so T2 firing early under
      # scheduler jitter cannot be mistaken for T1).
      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 300

      assert CityRegistry.whereis(city_id) == pid,
             "an orphaned, uncancelled timer must not stop the engine at its own " <>
               "(now-stale) deadline once a later viewer has come and gone"

      # And it does still stop, on T2, so the assertion above is not vacuously true
      # of an engine that simply never stops. 300ms already elapsed above, plus
      # 300ms more here comfortably clears T2's 400ms deadline.
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 300
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

    test "an engine that never gets a viewer stops on its own", %{city_id: city_id} do
      # SimulatorLive's dead render starts an engine (via CityEngine.snapshot/1)
      # before connected?(socket) is true, i.e. before attach/2 is ever called - this
      # test is that case with nothing attaching afterward either, so nothing but
      # handle_continue/2's own pre-attach linger can ever stop it. That linger is
      # armed from :engine_unattached_linger_ms, not :engine_linger_ms - a separate,
      # deliberately much shorter key (see the moduledoc's finding on cookieless
      # requests), so this test overrides that key rather than the post-viewer one.
      Application.put_env(:armchair_metropolist, :engine_unattached_linger_ms, @wide_linger_ms)

      {:ok, pid} = CityRegistry.ensure_started(city_id)
      ref = Process.monitor(pid)

      # No attach/2 call at all.
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, @wide_linger_ms + 500

      # Same registry-cleanup race as the other stop assertions in this describe
      # block - see wait_until/1's own comment.
      assert wait_until(fn -> CityRegistry.whereis(city_id) == nil end)
    end
  end

  describe "crash recovery" do
    # `restart: :transient` (city_engine.ex's `use GenServer` declaration) exists
    # specifically so a genuine crash still gets today's recovery behaviour, even
    # though a deliberate `:normal` stop (the freeze linger, above) must not be
    # resurrected. Nothing else in this file distinguishes the two: every other
    # test that stops an engine does so via `:linger_expired` (`:normal`) or
    # `DynamicSupervisor.terminate_child/2` (which discards the child spec first,
    # so it never restarts regardless of `:restart`). Without a test here, a future
    # edit to `:temporary` - which would also stop resurrecting a frozen engine,
    # so it might look like a plausible simplification - silently deletes crash
    # recovery with every other test still green.
    test "an abnormal exit restarts the engine under the same city id", %{city_id: city_id} do
      {:ok, pid} = CityRegistry.ensure_started(city_id)
      ref = Process.monitor(pid)

      # :kill is untrappable regardless of CityEngine's Process.flag(:trap_exit,
      # true), so this is a genuine abnormal termination and not a message the
      # engine's own handle_info/2 catch-all quietly absorbs.
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000

      new_pid =
        wait_until(fn ->
          case CityRegistry.whereis(city_id) do
            nil -> false
            ^pid -> false
            other -> other
          end
        end)

      assert is_pid(new_pid),
             "the supervisor must restart a :transient child after an abnormal exit"

      on_exit(fn ->
        capture_log(fn -> DynamicSupervisor.terminate_child(CityRegistry.Supervisor, new_pid) end)
      end)
    end

    # The mutation this guards against: if `:transient` above were silently doing
    # nothing - if every child restarted regardless of its declared `:restart`, or
    # `wait_until/1`'s window were simply generous enough to catch a coincidence -
    # the test above would pass for the wrong reason. Starting the same start_link/1
    # under an explicit :temporary override and confirming a :kill then does NOT
    # come back is that check: it is the state in which the assertion above must
    # fail, and does.
    test "a :temporary child, unlike this engine, does not come back", %{city_id: city_id} do
      spec = %{
        id: CityEngine,
        start: {CityEngine, :start_link, [[city_id: city_id]]},
        restart: :temporary,
        shutdown: 10_000
      }

      {:ok, pid} = DynamicSupervisor.start_child(CityRegistry.Supervisor, spec)
      ref = Process.monitor(pid)

      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000

      # Same registry-cleanup race as the "freezing" describe block above: our
      # monitor and the registry's own are independent, so the dead pid can still
      # be the answer for a moment after our :DOWN arrives - that lag is not a
      # restart and `wait_until/1` is what tells the two apart.
      assert wait_until(fn -> CityRegistry.whereis(city_id) == nil end),
             "the registry must eventually clear the dead pid"

      # ...and it must *stay* clear. A :temporary child restarting at all would
      # contradict the assertion above, but only a further pause with nothing
      # reappearing actually distinguishes "does not come back" from "hasn't yet".
      Process.sleep(100)

      refute CityRegistry.whereis(city_id),
             "a :temporary child must not be restarted after an abnormal exit"
    end
  end

  # Ten commercial nodes and no producers: baseline capacity cannot cover the
  # demand, so every resource sits below full satisfaction.
  defp starved_city do
    Enum.reduce(0..9, CityMap.new(40, 30), fn x, acc ->
      CityMap.put_node(acc, Node.new(x, 0, :commercial))
    end)
  end

  # The same ten consumers as `starved_city/0`, but placed through a *running* engine
  # rather than seeded into its stored snapshot. The notification tests need this one:
  # since an engine now derives `critical?` from the city it hydrates, a seeded deficit
  # is by design one that has already been announced, so seeding cannot produce the
  # edge those tests are about. Placing them is also the only way a real deficit is
  # ever unannounced - a player builds consumers, and the next tick is the first to see
  # it. Deliberately no tick here: `place/4` recomputes metrics but never notifies, so
  # each caller decides which tick discovers the deficit.
  defp starve(city_id) do
    Enum.each(0..9, fn x -> {:ok, _node} = CityEngine.place(city_id, x, 0, :commercial) end)
  end

  # The treasury every `starve/1` caller needs. Ten commercial blocks at 40 each is 400,
  # well past the 150 opening grant, so without this the fourth `place` comes back
  # `{:error, :insufficient_funds}` and the deficit under test never forms.
  #
  # Seeded *empty*: only the balance is preloaded, so `starve/1`'s consumers are still
  # placed through the running engine. That is the property its own docstring calls
  # load-bearing — a seeded deficit is by design one already announced, and could not
  # produce the unannounced edge these tests are about. Do not be tempted to seed
  # `starved_city/0` with money instead.
  #
  # 10_000 rather than the exact 400: "re-arms once satisfaction recovers" also demolishes
  # and rebuilds all ten, spending 900, and a figure that has to be recomputed whenever a
  # cost moves is a fixture that breaks for reasons unrelated to what it tests.
  defp seed_funded_city do
    StubSnapshotRepository.set_initial({:ok, {0, %{CityMap.new(40, 30) | money: 10_000.0}}})
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
