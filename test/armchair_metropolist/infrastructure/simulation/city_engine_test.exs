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

  @impl true
  def delete(_city_id), do: {:error, :disk_full}
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

  alias ArmchairMetropolist.Domain.Entities.{CityMap, MunicipalBond, Node}
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
    StubSnapshotRepository.set_initial({:ok, {{0, 0}, legacy_city()}})

    city_id = "test-#{System.unique_integer([:positive])}"
    {:ok, city_id: city_id}
  end

  defp legacy_city(width \\ 2, height \\ 2) do
    %{CityMap.new(width, height) | municipal_bond: MunicipalBond.legacy(), money: 500.0}
  end

  describe "hydration" do
    test "hydrates from the latest stored snapshot", %{city_id: city_id} do
      city = CityMap.put_node(legacy_city(40, 30), Node.new(1, 1, :power_plant))
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
      StubSnapshotRepository.set_initial({:ok, {3, legacy_city(40, 30)}})
      start_supervised!({CityEngine, city_id: city_id})

      assert {:ok, %{metrics: metrics}} = CityEngine.snapshot(city_id)

      assert Enum.sort(Map.keys(metrics.resources)) == Enum.sort(Node.resources()),
             "metrics must carry every resource at mount, not an empty map"

      assert metrics.resources.power.satisfaction == 1.0
    end

    test "falls back to an empty starting grid when nothing is stored", %{city_id: city_id} do
      StubSnapshotRepository.set_initial({:error, :not_found})
      start_supervised!({CityEngine, city_id: city_id})

      assert {:ok, %{city_map: city_map, metrics: metrics}} = CityEngine.snapshot(city_id)
      assert city_map.width == 2
      assert city_map.height == 2
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

      assert loaded.money == 0.0
      assert loaded.municipal_bond == MunicipalBond.legacy()
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
      assert city_map.width == 2
      assert city_map.height == 2
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
      StubSnapshotRepository.set_initial({:ok, {0, legacy_city(40, 30)}})
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

  describe "municipal financing commands" do
    test "issuance is serialized, persisted immediately, and broadcast", %{city_id: city_id} do
      StubSnapshotRepository.set_initial({:error, :not_found})
      start_supervised!({CityEngine, city_id: city_id})
      subscribe_simulation(city_id)

      assert :ok = CityEngine.issue_municipal_bond(city_id, 400.0)
      assert {:error, :already_financed} = CityEngine.issue_municipal_bond(city_id, 550.0)

      assert_receive {:city_metrics, %{money: 400.0, bond: %{original_principal: 400.0}}}
      refute_receive {:city_metrics, _}, 50

      assert [{^city_id, {0, 1}, saved}] = StubSnapshotRepository.saves()
      assert saved.money == 400.0
      assert saved.revision == 1
      assert saved.municipal_bond.original_principal == 400.0
    end

    test "planning stays at tick zero, refunds undo, and Begin sim starts and persists the clocks",
         %{city_id: city_id} do
      StubSnapshotRepository.set_initial({:error, :not_found})
      start_supervised!({CityEngine, city_id: city_id})
      subscribe_simulation(city_id)

      assert :ok = CityEngine.issue_municipal_bond(city_id, 400.0)
      assert {:ok, _park} = CityEngine.place(city_id, 0, 0, :park)
      assert {:ok, "0:0"} = CityEngine.demolish(city_id, 0, 0)
      assert {:ok, _house} = CityEngine.place(city_id, 0, 0, :residential)

      broadcast_tick(1)

      assert {:ok, %{city_map: planning}} = CityEngine.snapshot(city_id)
      assert planning.tick == 0
      assert planning.money == 385.0
      assert planning.municipal_bond.started_at_tick == nil

      assert :ok = CityEngine.begin_simulation(city_id)
      assert_receive {:city_metrics, %{bond: %{started: true}}}

      assert [{^city_id, {0, 5}, saved} | _earlier] = StubSnapshotRepository.saves()
      assert saved.municipal_bond.started_at_tick == 0

      broadcast_tick(2)
      assert {:ok, %{city_map: running}} = CityEngine.snapshot(city_id)
      assert running.tick == 1
    end

    test "optional redemption is persisted at a higher same-tick revision", %{city_id: city_id} do
      city = callable_bond_city()
      StubSnapshotRepository.set_initial({:ok, {CityMap.snapshot_order(city), city}})
      start_supervised!({CityEngine, city_id: city_id})
      subscribe_simulation(city_id)

      assert :ok = CityEngine.redeem_municipal_bond(city_id, :minimum)

      assert_receive {:city_metrics, %{money: 475.0, bond: %{outstanding_principal: 295.0}}}
      assert [{^city_id, {40, 4}, saved}] = StubSnapshotRepository.saves()
      assert saved.tick == 40
      assert saved.revision == 4
      assert saved.municipal_bond.outstanding_principal == 295.0
    end

    test "a commercial bridge quote is serialized, persisted, and broadcast", %{city_id: city_id} do
      city = commercial_bridge_city()
      StubSnapshotRepository.set_initial({:ok, {CityMap.snapshot_order(city), city}})
      start_supervised!({CityEngine, city_id: city_id})
      subscribe_simulation(city_id)

      assert :ok = CityEngine.issue_commercial_bond(city_id)
      assert {:error, :already_issued} = CityEngine.issue_commercial_bond(city_id)

      assert_receive {:city_metrics,
                      %{
                        money: 94.0,
                        commercial_bond: %{original_principal: 94.0},
                        commercial_bond_offer: nil
                      }}

      refute_receive {:city_metrics, _}, 50

      assert [{^city_id, {0, 1}, saved}] = StubSnapshotRepository.saves()
      assert saved.money == 94.0
      assert saved.revision == 1
      assert saved.commercial_bond.original_principal == 94.0
    end

    test "a refused redemption leaves treasury, revision, and persistence untouched", %{
      city_id: city_id
    } do
      city = %{callable_bond_city() | money: 20.0}
      StubSnapshotRepository.set_initial({:ok, {CityMap.snapshot_order(city), city}})
      start_supervised!({CityEngine, city_id: city_id})

      assert {:error, :insufficient_funds} =
               CityEngine.redeem_municipal_bond(city_id, :minimum)

      assert StubSnapshotRepository.saves() == []
      assert {:ok, %{city_map: current}} = CityEngine.snapshot(city_id)
      assert current.money == city.money
      assert current.revision == city.revision
    end
  end

  describe "infrastructure commands" do
    setup %{city_id: city_id} do
      # An explicit 40x30 rather than a fresh city: a fresh city is now a 2x2 where (3, 4) is
      # out of bounds. Above the growth cap, so it also never grows under a test that is not
      # about growth.
      StubSnapshotRepository.set_initial({:ok, {0, legacy_city(40, 30)}})
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
      StubSnapshotRepository.set_initial({:ok, {{0, 0}, legacy_city()}})
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
      StubSnapshotRepository.set_initial({:ok, {0, %{legacy_city(40, 30) | money: 20.0}}})
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
      StubSnapshotRepository.set_initial({:ok, {0, %{legacy_city(40, 30) | money: 100.0}}})
      start_supervised!({CityEngine, city_id: city_id})
      subscribe_simulation(city_id)

      {:ok, _node} = CityEngine.place(city_id, 1, 1, :park)

      assert_receive {:city_metrics, metrics}
      assert metrics.money == 80.0
    end

    test "a refused command leaves the engine's balance untouched", %{city_id: city_id} do
      # The observable form of "a refusal changes nothing". The use-case tests cannot check
      # it — a refusal returns no map, so the only `CityMap` in their scope is their own
      # binding — but the engine holds the balance in a process that outlives the call, so
      # here it is real state read back after the fact.
      #
      # The fixture is chosen so a premature debit reads a *different* number rather than a
      # coinciding one. 20.0 seeded, minus 15.0 for the residential, leaves 5.0; a refusal
      # that debited first and committed would read 0.0 for the park (5 − 20, floored) and
      # 0.0 for the demolition (5 − 10, floored). Every figure below is 5.0, so none of
      # them can be satisfied by an accidental zero.
      #
      # The affordable place is also the fixture's discriminator for the debit-before-the-
      # gate mutation: 20.0 only just covers the residential's 15.0, so an implementation
      # that debits before comparing sees 5.0 against a cost of 15.0 and refuses a command
      # that must succeed.
      StubSnapshotRepository.set_initial({:ok, {0, %{legacy_city(40, 30) | money: 20.0}}})
      start_supervised!({CityEngine, city_id: city_id})

      assert {:ok, _node} = CityEngine.place(city_id, 1, 1, :residential)
      assert {:ok, %{city_map: %{money: 5.0}}} = CityEngine.snapshot(city_id)

      # Too poor for a park at 20. Refused, and the 5.0 must survive it.
      assert {:error, :insufficient_funds} = CityEngine.place(city_id, 2, 2, :park)

      assert {:ok, %{city_map: city_map, metrics: metrics}} = CityEngine.snapshot(city_id)
      assert city_map.money == 5.0
      assert metrics.money == 5.0, "a refusal must not recompute metrics either"

      # And too poor for the flat 10 demolition, so the node it could not afford to remove
      # is still standing — the other half of what the use-case test used to claim.
      assert {:error, :insufficient_funds} = CityEngine.demolish(city_id, 1, 1)

      assert {:ok, %{city_map: city_map}} = CityEngine.snapshot(city_id)
      assert city_map.money == 5.0
      refute CityMap.get_node(city_map, 1, 1) == nil
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
      assert [{^city_id, {2, 2}, saved}] = StubSnapshotRepository.saves()

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

      assert [{^city_id, {2, 2}, ^saved}] = StubSnapshotRepository.saves(),
             "tick 3 is not a checkpoint"
    end

    test "treats a non-positive checkpoint interval as checkpointing disabled", %{
      city_id: city_id
    } do
      # rem(tick, 0) raises inside handle_info/2, which would put the engine in
      # a restart loop on every tick rather than failing at boot.
      Application.put_env(:armchair_metropolist, :checkpoint_every_ticks, 0)
      StubSnapshotRepository.set_initial({:ok, {{0, 0}, legacy_city()}})
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
      StubSnapshotRepository.set_initial({:ok, {{0, 0}, legacy_city()}})
      pid = start_supervised!({CityEngine, city_id: city_id})
      {:ok, _node} = CityEngine.place(city_id, 1, 1, :power_plant)

      assert StubSnapshotRepository.saves() == []

      ref = Process.monitor(pid)
      stop_supervised!(CityEngine)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000

      assert [{^city_id, {0, 1}, saved} | _] = StubSnapshotRepository.saves()
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

      assert [{^city_id, {1, 1}, saved} | _] = StubSnapshotRepository.saves()
      assert saved.tick == 1
    end

    test "warns rather than failing when the adapter refuses a stale save", %{city_id: city_id} do
      # Without this override tick 1 is not a checkpoint (the default interval is
      # 50), and the save the assertions below depend on would never happen.
      Application.put_env(:armchair_metropolist, :checkpoint_every_ticks, 1)
      StubSnapshotRepository.set_initial({:ok, {3, legacy_city(40, 30)}})
      start_supervised!({CityEngine, city_id: city_id})
      StubSnapshotRepository.refuse_saves_as_stale({99, 0})

      log =
        capture_log(fn ->
          {:ok, _node} = CityEngine.place(city_id, 1, 1, :power_plant)
          Phoenix.PubSub.broadcast(ArmchairMetropolist.PubSub, @tick_topic, {:tick, 1})
          # Let the engine handle the tick, whose checkpoint attempts the save.
          {:ok, _} = CityEngine.snapshot(city_id)
        end)

      assert log =~ "declined to persist"
      assert log =~ "{99, 0}"
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
        :ok = CityEngine.issue_municipal_bond(city_id, 400.0)
        {:ok, node} = CityEngine.place(city_id, 1, 1, :power_plant)
        :ok = CityEngine.begin_simulation(city_id)

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
      :ok = CityEngine.issue_municipal_bond(city_id, 400.0)
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
      # Exactly enough to place the ten shops, leaving no treasury for imports.
      StubSnapshotRepository.set_initial({:ok, {0, %{legacy_city(40, 30) | money: 400.0}}})
      start_supervised!({CityEngine, city_id: city_id})
      starve(city_id)

      broadcast_tick(1)

      assert_receive {:notified, title, body}, 1_000
      assert is_binary(title)
      assert body =~ "power at 55% of demand"

      # The first tick earns 300, which reaches the post-tick treasury and is then
      # available to the metrics' next-tick market plan. That budget is split across
      # power, water, waste and labour; traffic remains wholly unpurchasable. Imported
      # workers add enough commuter traffic to make congestion the worst flow shortage,
      # and that unsafe traffic has created an untreated injury stock by the next plan. The
      # order below is the severity signal the operator reads first and is pinned rather
      # than incidental.
      named =
        body
        |> String.split(", ")
        |> Enum.map(fn part -> part |> String.split(" ", parts: 2) |> hd() end)

      assert named == ["injuries", "traffic", "waste", "labour", "power", "water"]
    end

    test "does not notify a city that is meeting demand", %{city_id: city_id} do
      StubSnapshotRepository.set_initial({:ok, {0, legacy_city(40, 30)}})
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

      # Demolishing every consumer removes the flow demand, but the injuries their traffic
      # created are a stock. Two hospitals clear that stock so every resource returns to
      # 1.0 and the notification can re-arm.
      Enum.each(0..9, fn x -> {:ok, _id} = CityEngine.demolish(city_id, x, 0) end)
      {:ok, _node} = CityEngine.place(city_id, 10, 0, :hospital)
      {:ok, _node} = CityEngine.place(city_id, 11, 0, :hospital)
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

    # Ten houses emit 100 waste against the free baseline's 40. `AdvanceCityTick`
    # computes metrics from the *post*-tick map (see its own moduledoc), and
    # `SimulationCalculator.advance_tick/1` writes this same tick's waste deficit
    # (100 demanded - 40 supplied = 60) into that post-tick map before metrics are
    # built from it — so the very first notified tick already reads the backlog:
    # available (40 - 60 = -20) over demand (100) is -0.2, not merely short of 1.0.
    #
    # This is why the fixture is ten houses and not fewer: at six (the free
    # baseline covers most of a 60-demand load) the first tick's deficit is only
    # 20, available stays positive at 20, and satisfaction lands at +0.33 — a
    # deficit, but not the negative one this test exists to clamp. Measured by
    # running `SimulationCalculator.advance_tick/1` by hand for six through
    # twelve houses: nine is the first count whose first-tick satisfaction goes
    # negative, and ten was chosen over nine only to match this file's own
    # `starve/1` idiom of ten placements.
    test "a waste backlog is reported at 0% rather than a negative percentage",
         %{city_id: city_id} do
      # Exactly enough to place the ten houses, leaving no treasury to buy disposal.
      StubSnapshotRepository.set_initial({:ok, {0, %{legacy_city(40, 30) | money: 150.0}}})
      start_supervised!({CityEngine, city_id: city_id})
      Enum.each(0..9, fn x -> {:ok, _node} = CityEngine.place(city_id, x, 0, :residential) end)

      broadcast_tick(1)
      assert_receive {:notified, _title, body}, 1_000

      assert body =~ "waste at 0% of demand"

      # The clamp is the point: unclamped this reads "waste at -20% of demand".
      # Asserted on the whole body rather than on the substring above, because a
      # negative figure for any other resource would be the same defect.
      refute body =~ "-"
    end
  end

  describe "isolation between cities" do
    setup do
      # An explicit 40x30 rather than a fresh city: a fresh city is now a 2x2 where (3, 4) is
      # out of bounds. Above the growth cap, so it also never grows under a test that is not
      # about growth. No `set_initial` here at all previously rode the stub's own
      # `{:error, :not_found}` default, which was harmless while a fresh city was 40x30 and
      # is not anymore.
      StubSnapshotRepository.set_initial({:ok, {0, legacy_city(40, 30)}})
      :ok
    end

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
      # An explicit 40x30 rather than a fresh city: this test places at (3, 4), out of
      # bounds on the 2x2 a fresh city starts as now, and it is about reload-on-reattach,
      # not grid size.
      StubSnapshotRepository.set_initial({:ok, {0, legacy_city(40, 30)}})
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

  describe "freezing a stalled city" do
    test "ignores the clock once the city has stalled", %{city_id: city_id} do
      StubSnapshotRepository.set_initial({:ok, {3, dead_city(3, 0.0)}})
      start_supervised!({CityEngine, city_id: city_id})

      {:ok, %{metrics: metrics}} = CityEngine.snapshot(city_id)
      assert metrics.stalled

      broadcast_tick(1)

      # snapshot/1 is a GenServer.call, so returning means the broadcast above has
      # already been handled — or deliberately ignored.
      {:ok, %{city_map: city_map, metrics: after_tick}} = CityEngine.snapshot(city_id)
      assert city_map.tick == 3
      assert after_tick.stalled
    end

    test "a running city still advances", %{city_id: city_id} do
      # The other direction. A freeze that always fires and a freeze that never fires
      # are different bugs, and only one of them is caught by the test above.
      StubSnapshotRepository.set_initial({:ok, {3, %{dead_city(2, 0.0) | money: 30.0}}})
      start_supervised!({CityEngine, city_id: city_id})

      {:ok, %{metrics: metrics}} = CityEngine.snapshot(city_id)
      refute metrics.stalled

      broadcast_tick(1)

      {:ok, %{city_map: city_map}} = CityEngine.snapshot(city_id)
      assert city_map.tick == 4
    end

    test "a placement unfreezes a stalled city that can still afford one", %{city_id: city_id} do
      # The freeze is not a lockout. Seven dead houses have no money demand at all —
      # residential consumes none — so their treasury never drained, and 105 covers the
      # 80 a power plant costs.
      #
      # What unfreezes the city is the *new block's own health*, not a rescue of the
      # houses: `stalled?` is `Enum.all?`, and a node placed at 100.0 fails the
      # `health == @min_health` half immediately. Measured, the placement does not in
      # fact rescue the houses. The clock restarting is the whole claim here; do not
      # restate it as a recovery.
      StubSnapshotRepository.set_initial({:ok, {3, %{dead_city(7, 0.0) | money: 105.0}}})
      start_supervised!({CityEngine, city_id: city_id})

      assert {:ok, %{metrics: %{stalled: true}}} = CityEngine.snapshot(city_id)

      assert {:ok, _node} = CityEngine.place(city_id, 10, 10, :power_plant)

      assert {:ok, %{metrics: %{stalled: false}}} = CityEngine.snapshot(city_id)
    end

    test "demolishing back inside traffic and the import budget unfreezes without building", %{
      city_id: city_id
    } do
      # The other unfreeze, and the one the game-over copy leans on: four dead houses
      # overrun traffic and need purchasable resources. Tearing one down removes the
      # traffic deficit and leaves 45 power plus 6 water imports, exactly covered by the
      # remaining treasury, so the survivors can regenerate.
      #
      # Seeded at 61: the demolition fee plus the surviving city's 51-unit import bill.
      StubSnapshotRepository.set_initial({:ok, {3, %{dead_city(4, 0.0) | money: 61.0}}})
      start_supervised!({CityEngine, city_id: city_id})

      assert {:ok, %{metrics: %{stalled: true}}} = CityEngine.snapshot(city_id)

      assert {:ok, _id} = CityEngine.demolish(city_id, 3, 0)

      assert {:ok, %{metrics: %{stalled: false}}} = CityEngine.snapshot(city_id)
    end

    test "demolishing into a draining landfill unfreezes a city with nobody fully supplied",
         %{city_id: city_id} do
      # The third unfreeze route, and the one neither test above exercises: no survivor
      # is fully supplied (three dead houses still have no power) and the grid is not
      # empty, but cutting five
      # houses to three drops waste demand from 50 to 30 — under the baseline's 40 — so
      # a landfill that was growing starts draining instead. `stalled?/3` reads that
      # off `deficit < stock`, not off anyone's satisfaction.
      #
      # This is the path `handle_call({:demolish, ...})` has to get right: it must
      # recompute `metrics` from the *post*-demolition city, not carry the stale
      # `stalled: true` forward, or the very next `{:tick, ...}` still matches
      # `handle_info({:tick, _}, %{metrics: %{stalled: true}})` and the city never
      # ticks again — the landfill would sit at 130 forever instead of draining.
      dead_parks =
        for x <- 0..6,
            do: %Node{Node.new(x, 1, :park) | health: 0.0, status: :offline}

      seeded =
        Enum.reduce(dead_parks, %{dead_city(5, 0.0) | waste_stock: 130.0, money: 20.0}, fn
          node, city -> CityMap.put_node(city, node)
        end)

      StubSnapshotRepository.set_initial({:ok, {3, seeded}})
      start_supervised!({CityEngine, city_id: city_id})

      assert {:ok, %{metrics: %{stalled: true}}} = CityEngine.snapshot(city_id)

      assert {:ok, _id} = CityEngine.demolish(city_id, 0, 0)
      assert {:ok, _id} = CityEngine.demolish(city_id, 1, 0)

      assert {:ok, %{metrics: %{stalled: false}}} = CityEngine.snapshot(city_id)

      broadcast_tick(1)

      {:ok, %{city_map: city_map, metrics: metrics}} = CityEngine.snapshot(city_id)

      assert city_map.tick == 4,
             "the engine must actually have ticked, not just recomputed metrics"

      # 3 houses emit 30 against the baseline's 40, so 130 - (40 - 30) = 120: the
      # backlog drains by 10, it does not merely fail to grow.
      assert city_map.waste_stock == 120.0, "the landfill must be draining, not held"
      refute metrics.stalled, "still thirteen ticks from empty, not stalled again yet"
    end
  end

  describe "grid growth" do
    setup %{city_id: city_id} do
      two =
        legacy_city(2, 2)
        |> CityMap.put_node(Node.new(0, 0, :park))
        |> CityMap.put_node(Node.new(1, 0, :park))

      StubSnapshotRepository.set_initial({:ok, {0, two}})
      start_supervised!({CityEngine, city_id: city_id})
      Phoenix.PubSub.subscribe(ArmchairMetropolist.PubSub, CityEngine.topic(city_id))
      :ok
    end

    test "broadcasts the grown map before the node that grew it", %{city_id: city_id} do
      assert {:ok, _node} = CityEngine.place(city_id, 0, 1, :park)

      # Received with a catch-all and *then* matched, deliberately. `assert_receive` scans
      # the whole mailbox, so two `assert_receive`s in sequence pass in either order and
      # would not pin the ordering at all. A subscriber that sees the node before the
      # resize paints it onto a grid that is still 2x2.
      assert_receive first when is_tuple(first)
      assert match?({:city_grew, %CityMap{width: 4, height: 4}}, first)

      assert_receive second when is_tuple(second)
      assert match?({:city_node_placed, %Node{id: "0:1"}}, second)

      assert_receive {:city_metrics, %{node_count: 3}}
    end

    test "does not announce growth on a placement that did not grow", %{city_id: city_id} do
      # The 2x2 holds two nodes; a third grows it, so demolish one first and place into a
      # map that stays at 2x2.
      assert {:ok, _id} = CityEngine.demolish(city_id, 0, 0)
      assert {:ok, _node} = CityEngine.place(city_id, 0, 1, :park)

      refute_receive {:city_grew, _}, 200
      assert_receive {:city_node_placed, %Node{id: "0:1"}}
      # Asserted in this case too, not only in the growing one: an early return that skipped
      # the metrics on the non-growth path would otherwise go unnoticed.
      assert_receive {:city_metrics, %{node_count: 2}}
    end
  end

  describe "reset/1" do
    test "clears the city, empties the treasury, and returns to unissued tick 0", %{
      city_id: city_id
    } do
      StubSnapshotRepository.set_initial({:ok, {3, dead_city(3, 0.0)}})
      start_supervised!({CityEngine, city_id: city_id})

      assert :ok = CityEngine.reset(city_id)

      {:ok, %{city_map: city_map, metrics: metrics}} = CityEngine.snapshot(city_id)
      assert city_map.nodes == %{}
      assert city_map.tick == 0
      assert city_map.money == 0.0
      assert city_map.municipal_bond == nil
      refute metrics.stalled
    end

    test "deletes the stored snapshot before saving the new city", %{city_id: city_id} do
      # The ordering is the error handling: if the delete fails, the save that follows is
      # refused as stale and lands in the existing warning path. Reversed, the save is
      # refused first and then the delete throws the new city away too.
      StubSnapshotRepository.set_initial({:ok, {3, dead_city(3, 0.0)}})
      start_supervised!({CityEngine, city_id: city_id})

      assert :ok = CityEngine.reset(city_id)

      # Newest first, so the save is ahead of the delete.
      assert [{:save, ^city_id, {0, 0}}, {:delete, ^city_id} | _] =
               StubSnapshotRepository.calls()
    end

    test "still resets in memory when the snapshot delete fails", %{city_id: city_id} do
      StubSnapshotRepository.set_initial({:ok, {3, dead_city(3, 0.0)}})
      start_supervised!({CityEngine, city_id: city_id})
      StubSnapshotRepository.fail_deletes(:disk_full)

      log = capture_log(fn -> assert :ok = CityEngine.reset(city_id) end)

      {:ok, %{city_map: city_map}} = CityEngine.snapshot(city_id)
      assert city_map.nodes == %{}
      assert log =~ "disk_full"
    end

    test "broadcasts the reset and the new metrics", %{city_id: city_id} do
      StubSnapshotRepository.set_initial({:ok, {3, dead_city(3, 0.0)}})
      start_supervised!({CityEngine, city_id: city_id})

      subscribe_simulation(city_id)

      assert :ok = CityEngine.reset(city_id)

      # Bound in arrival order and matched afterwards, because two separate
      # `assert_receive`s would *not* pin the order: each scans the whole mailbox, so
      # `assert_receive :city_reset` followed by `assert_receive {:city_metrics, _}` passes
      # whichever way round the two arrived. Order is the behaviour worth having — a viewer
      # clears its stream on `:city_reset` and re-renders on the metrics that follow, so
      # reversed it paints the new figures over the old grid for a frame. Nothing else
      # sends to this process: it subscribes to one topic and starts one engine.
      assert_receive first
      assert_receive second

      assert match?({:city_reset, %CityMap{}}, first)
      assert {:city_metrics, %{node_count: 0, tick: 0}} = second
    end

    test "a reset broadcasts the new city map, not a bare atom", %{city_id: city_id} do
      StubSnapshotRepository.set_initial({:ok, {0, legacy_city(12, 12)}})
      start_supervised!({CityEngine, city_id: city_id})
      Phoenix.PubSub.subscribe(ArmchairMetropolist.PubSub, CityEngine.topic(city_id))

      assert :ok = CityEngine.reset(city_id)

      # The map travels with the message because the view has to resize: a reset returns a
      # 2x2 whatever grid the city had grown to. Seeded at 12x12 so that is visible — from a
      # 2x2 the assertion would hold without `reset/1` changing the grid at all.
      assert_receive {:city_reset, %CityMap{width: 2, height: 2, nodes: nodes}}
      assert nodes == %{}
    end

    test "a reset city ticks again", %{city_id: city_id} do
      # The freeze from Task 4 must not survive the reset.
      StubSnapshotRepository.set_initial({:ok, {3, dead_city(3, 0.0)}})
      start_supervised!({CityEngine, city_id: city_id})

      assert :ok = CityEngine.reset(city_id)
      assert :ok = CityEngine.issue_municipal_bond(city_id, 250.0)
      assert {:ok, _node} = CityEngine.place(city_id, 0, 0, :park)
      assert :ok = CityEngine.begin_simulation(city_id)

      broadcast_tick(1)

      {:ok, %{city_map: city_map}} = CityEngine.snapshot(city_id)
      assert city_map.tick == 1
    end

    test "notifies a fresh deficit in the new city rather than inheriting the old one's flag",
         %{city_id: city_id} do
      # dead_city(3, 0.0) is already in critical deficit at hydration - three dead houses
      # have zero power satisfaction - so `critical?`
      # comes out of handle_continue/2 as `true` before reset ever runs. If
      # handle_call(:reset, ...) left that flag alone instead of re-deriving it from the
      # brand-new (empty, therefore fully satisfied) city, the stale `true` would still be
      # sitting there the next time notify_deficits/2 runs. Its `{_resources, true}` arm
      # reads that as "already told the player", so the very first deficit anyone creates
      # in the new city would reach the engine and never reach the player - silently, with
      # every other assertion in this describe block still green. That is the mirror image
      # of the moduledoc's "three byte-identical notifications" story: there the flag was
      # too eager, here a leftover flag would be too quiet.
      #
      # Five commercial blocks draw 45 traffic against the baseline's 30. Traffic is the
      # one shortfall the external market cannot buy away, so this remains a real deficit
      # despite the reset city's newly authorized bond proceeds.
      StubSnapshotRepository.set_initial({:ok, {3, dead_city(3, 0.0)}})
      start_supervised!({CityEngine, city_id: city_id})

      assert :ok = CityEngine.reset(city_id)
      assert :ok = CityEngine.issue_municipal_bond(city_id, 550.0)

      for {x, y} <- [{0, 0}, {1, 0}, {0, 1}, {1, 1}, {2, 0}] do
        {:ok, _node} = CityEngine.place(city_id, x, y, :commercial)
      end

      assert :ok = CityEngine.begin_simulation(city_id)

      broadcast_tick(1)

      assert_receive {:notified, _title, _body}, 1_000
    end
  end

  # Ten commercial nodes and no producers: baseline capacity cannot cover the
  # demand, so every resource sits below full satisfaction.
  defp starved_city do
    Enum.reduce(0..9, legacy_city(40, 30), fn x, acc ->
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

  # The treasury one `starve/1` caller needs. Ten commercial blocks at 40 each is 400 —
  # exactly the old 400 treasury fixture, leaving nothing — so `starve/1` on its own just fits
  # unaided. What does not fit is "re-arms once satisfaction recovers", which demolishes
  # and rebuilds all ten on top of that. Measured 2026-08-07 by reducing this seeding to
  # the plain grant: that one test fails and the other four `starve/1` callers pass.
  #
  # This is grandfathered test state, not a new-city financing path.
  #
  # Seeded *empty*: only the balance is preloaded, so `starve/1`'s consumers are still
  # placed through the running engine. That is the property its own docstring calls
  # load-bearing — a seeded deficit is by design one already announced, and could not
  # produce the unannounced edge these tests are about. Do not be tempted to seed
  # `starved_city/0` with money instead.
  #
  # 10_000 rather than the 900 that sequence gross-costs — 400 to place ten, 100 to
  # demolish ten, 400 to replace them: a figure that has to be recomputed whenever a
  # construction or demolition cost moves is a fixture that breaks for reasons unrelated
  # to what it tests.
  defp seed_funded_city do
    StubSnapshotRepository.set_initial({:ok, {0, %{legacy_city(40, 30) | money: 10_000.0}}})
  end

  defp callable_bond_city do
    {:ok, bond} = MunicipalBond.new(400.0)
    bond = MunicipalBond.start(bond, 0)

    bond =
      Enum.reduce(20..39, bond, fn tick, current ->
        MunicipalBond.service(current, tick, 10_000.0).bond
      end)

    %{CityMap.new() | tick: 40, revision: 3, money: 500.0, municipal_bond: bond}
  end

  defp commercial_bridge_city do
    legacy_city(40, 30)
    |> CityMap.put_node(Node.new(0, 0, :residential))
    |> CityMap.put_node(Node.new(1, 0, :power_plant))
    |> CityMap.put_node(Node.new(2, 0, :water_plant))
    |> Map.put(:money, 0.0)
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

  # `house_count` residential blocks, all pinned to `health` (and to whatever status
  # that health implies) and nothing else on the map — the shape "freezing a stalled
  # city" needs at both ends of the cliff: 2 houses draw 30 power against the free
  # baseline of 40 and regenerate, 3 draw 45 and starve. `tick: 3` matches the seeded
  # `StubSnapshotRepository` tick so callers can assert the frozen tick never moves.
  defp dead_city(house_count, health) do
    city =
      Enum.reduce(0..(house_count - 1)//1, legacy_city(40, 30), fn x, map ->
        CityMap.put_node(map, %Node{
          Node.new(x, 0, :residential)
          | health: health,
            status: Node.status_for(health)
        })
      end)

    %{city | tick: 3, money: 0.0}
  end

  # No matching unsubscribe: the subscription is owned by the test process and
  # PubSub drops it when that process exits at the end of the test.
  defp subscribe_simulation(city_id) do
    :ok = Phoenix.PubSub.subscribe(ArmchairMetropolist.PubSub, CityEngine.topic(city_id))
  end
end
