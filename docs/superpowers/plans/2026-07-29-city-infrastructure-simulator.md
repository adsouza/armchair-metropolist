# City Infrastructure Simulator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A real-time event-driven city infrastructure simulator with a pure functional domain, a non-blocking OTP engine, diff-based LiveView updates, and two deployment targets (server on Postgres, desktop on Tauri).

**Architecture:** Clean/Hexagonal with compile-time enforcement. Five `boundary` boundaries; dependencies point inward only. Two ports (`SnapshotRepository`, `Notifier`) with four adapters. A `TickServer` clock broadcasts on PubSub; a `CityEngine` GenServer consumes ticks, delegates to pure use cases, and broadcasts only per-tick diffs.

**Tech Stack:** Elixir 1.20.2 / OTP 29, Phoenix 1.8.9, LiveView 1.2.8, Ecto 3.14.1, Postgrex 0.22.3, `boundary` 0.10.4, `stream_data` 1.4, `ex_tauri` 0.2.0 + Burrito.

**Spec:** `docs/superpowers/specs/2026-07-29-city-infrastructure-simulator-design.md` — read the referenced section before each task.

## Global Constraints

- Elixir `~> 1.17`, running on Elixir 1.20.2 / OTP 29 (erts 17.0.4).
- **`Domain` is `type: :strict, deps: []`; `Domain.Services` is `type: :strict, deps: [ArmchairMetropolist.Domain]`.** Neither may reach OTP (`GenServer`, `Agent`, `Task`, `Process`, `Supervisor`, `:ets`, `:timer`), Ecto, or Phoenix. Enforced by `boundary` *and* by `domain_purity_test`.
- Grid is **40 × 30**. Tick interval **1000ms**.
- Four resources: `:power`, `:water`, `:waste`, `:traffic`. Seven node types: `:power_plant`, `:water_plant`, `:industrial`, `:road_hub`, `:residential`, `:commercial`, `:park`.
- Baseline municipal capacity: `%{power: 40, water: 40, waste: 40, traffic: 40}`.
- Health is a **float** `0.0..100.0`. Regen `+1.0`; decay `-(1.0 - worst) * 6.0`.
- Status: `:online` when `health >= 60.0`; `:degraded` when `20.0 <= health < 60.0`; `:offline` when `health < 20.0`.
- Node id format is exactly `"#{x}:#{y}"` — it doubles as the LiveView stream DOM id.
- `boundary` violations are **warnings**; `mix compile --force --warnings-as-errors` is the gate.
- `compilers:` must be `[:boundary, :phoenix_live_view] ++ Mix.compilers()` — **prepend**, do not replace; dropping `:phoenix_live_view` breaks LiveView compilation.
- Commit after every task. Never commit with failing tests.
- `mix.exs` declares `elixir: "~> 1.17"`, so **do not use stdlib functions newer than 1.17**
  (e.g. `Enum.sum_by/2` is `since: 1.18.0`). The dev machine runs 1.20.2, so such calls compile
  and run fine here and would only fail on a 1.17 toolchain — nothing warns you.
- PubSub topics: `"city_tick"` (internal clock), `"city_simulation"` (UI updates).
- Postgres dev/test databases already exist and connect with `postgres`/`postgres` on `localhost`.

---

## Task 1: Foundation — boundaries, skeletons, Repo relocation

**Owner:** executed inline before subagent dispatch (serial; everything depends on it).

**Files:**
- Modify: `mix.exs`
- Modify: `config/config.exs`, `config/dev.exs`, `config/test.exs`, `config/runtime.exs`
- Move: `lib/armchair_metropolist/repo.ex` → `lib/armchair_metropolist/infrastructure/persistence/repo.ex`
- Modify: `lib/armchair_metropolist/application.ex`, `lib/armchair_metropolist_web.ex`
- Create: `lib/armchair_metropolist/domain.ex`, `domain/services.ex`, `use_cases.ex`, `infrastructure.ex`
- Create: skeleton modules listed in Step 4

**Interfaces:**
- Consumes: nothing.
- Produces: every module name later tasks implement into, plus the two port behaviours. After this task the project compiles clean with `--warnings-as-errors` and all boundary declarations are final — **later tasks must not edit `domain.ex`, `services.ex`, `use_cases.ex`, `infrastructure.ex`, or `armchair_metropolist_web.ex` boundary blocks.**

- [ ] **Step 1: Add dependencies**

In `mix.exs` `deps/0`, add:

```elixir
{:boundary, "~> 0.10", runtime: false},
{:stream_data, "~> 1.4", only: [:test]},
```

- [ ] **Step 2: Wire compilers and boundary config**

In `mix.exs` `project/0`, replace the `compilers:` line and add `boundary:`:

```elixir
compilers: [:boundary, :phoenix_live_view] ++ Mix.compilers(),
boundary: [
  default: [
    check: [
      apps: [
        :ecto, :ecto_sql, :phoenix, :phoenix_live_view,
        :phoenix_pubsub, :postgrex, {:mix, :runtime}
      ]
    ]
  ]
],
```

Add a `check` alias in `aliases/0`:

```elixir
check: ["compile --force --warnings-as-errors", "test"]
```

Do **not** add `test_coverage: [threshold: 90]` yet — Task 12 adds it, once real coverage exists.

- [ ] **Step 3: Relocate the Repo**

`git mv lib/armchair_metropolist/repo.ex lib/armchair_metropolist/infrastructure/persistence/repo.ex`, rename the module to `ArmchairMetropolist.Infrastructure.Persistence.Repo`, then update every reference: `config/config.exs` (`ecto_repos:`), `config/dev.exs`, `config/test.exs`, `config/runtime.exs`, `lib/armchair_metropolist/application.ex`, and `test/support/data_case.ex` plus `test/support/conn_case.ex` if they reference it.

Search for stragglers: `grep -rn "ArmchairMetropolist.Repo" lib test config`.

- [ ] **Step 4: Create skeleton modules**

Boundary rejects `exports:` naming a module that does not exist, so every exported module must exist now. Create these with struct/behaviour definitions only:

`lib/armchair_metropolist/domain/entities/node.ex`:

```elixir
defmodule ArmchairMetropolist.Domain.Entities.Node do
  @moduledoc "A single piece of placed city infrastructure."

  @type resource :: :power | :water | :waste | :traffic
  @type node_type ::
          :power_plant | :water_plant | :industrial | :road_hub
          | :residential | :commercial | :park
  @type status :: :online | :degraded | :offline

  @type t :: %__MODULE__{
          id: String.t(),
          x: non_neg_integer(),
          y: non_neg_integer(),
          type: node_type(),
          health: float(),
          status: status()
        }

  defstruct [:id, :x, :y, :type, :health, :status]
end
```

`lib/armchair_metropolist/domain/entities/city_map.ex`:

```elixir
defmodule ArmchairMetropolist.Domain.Entities.CityMap do
  @moduledoc "The city grid and the infrastructure placed on it."

  alias ArmchairMetropolist.Domain.Entities.Node

  @type t :: %__MODULE__{
          width: pos_integer(),
          height: pos_integer(),
          tick: non_neg_integer(),
          nodes: %{optional(String.t()) => Node.t()}
        }

  defstruct width: 40, height: 30, tick: 0, nodes: %{}
end
```

`lib/armchair_metropolist/domain/entities/simulation_metrics.ex`:

```elixir
defmodule ArmchairMetropolist.Domain.Entities.SimulationMetrics do
  @moduledoc "Aggregate supply/demand and health figures for one tick."

  @type resource_stats :: %{
          supplied: float(),
          demanded: float(),
          deficit: float(),
          satisfaction: float()
        }

  @type t :: %__MODULE__{
          tick: non_neg_integer(),
          resources: %{optional(atom()) => resource_stats()},
          node_count: non_neg_integer(),
          avg_health: float(),
          offline_count: non_neg_integer()
        }

  defstruct tick: 0, resources: %{}, node_count: 0, avg_health: 0.0, offline_count: 0
end
```

`lib/armchair_metropolist/domain/ports/snapshot_repository.ex`:

```elixir
defmodule ArmchairMetropolist.Domain.Ports.SnapshotRepository do
  @moduledoc """
  Output port for snapshot persistence.

  Speaks `CityMap` only. Serialisation and checksumming are adapter concerns —
  if `binary` or `checksum` appeared here, the domain would have learned about
  storage encoding.
  """

  alias ArmchairMetropolist.Domain.Entities.CityMap

  @callback load_latest() ::
              {:ok, {non_neg_integer(), CityMap.t()}} | {:error, :not_found | term()}
  @callback save(non_neg_integer(), CityMap.t()) :: :ok | {:error, term()}
end
```

`lib/armchair_metropolist/domain/ports/notifier.ex`:

```elixir
defmodule ArmchairMetropolist.Domain.Ports.Notifier do
  @moduledoc "Output port for user-facing notifications."

  @callback notify(String.t(), String.t()) :: :ok | {:error, term()}
end
```

`lib/armchair_metropolist/domain/services/simulation_calculator.ex` — module with `@moduledoc` only.

Also create empty-bodied modules (moduledoc only) so later tasks have a target:
`use_cases/advance_city_tick.ex`, `use_cases/manage_infrastructure.ex`,
`infrastructure/persistence/city_snapshot.ex`, `infrastructure/persistence/snapshot_store.ex`,
`infrastructure/persistence/file_snapshot_store.ex`,
`infrastructure/simulation/city_engine.ex`, `infrastructure/simulation/tick_server.ex`,
`infrastructure/desktop/log_notifier.ex`.

- [ ] **Step 5: Create the boundary declarations**

`lib/armchair_metropolist/domain.ex`:

```elixir
defmodule ArmchairMetropolist.Domain do
  use Boundary,
    type: :strict,
    deps: [],
    exports: [
      Entities.CityMap,
      Entities.Node,
      Entities.SimulationMetrics,
      Ports.SnapshotRepository,
      Ports.Notifier
    ]
end
```

`lib/armchair_metropolist/domain/services.ex`:

```elixir
defmodule ArmchairMetropolist.Domain.Services do
  use Boundary,
    top_level?: true,
    type: :strict,
    deps: [ArmchairMetropolist.Domain],
    exports: [SimulationCalculator]
end
```

`lib/armchair_metropolist/use_cases.ex`:

```elixir
defmodule ArmchairMetropolist.UseCases do
  use Boundary,
    deps: [ArmchairMetropolist.Domain, ArmchairMetropolist.Domain.Services],
    exports: :all
end
```

`lib/armchair_metropolist/infrastructure.ex`:

```elixir
defmodule ArmchairMetropolist.Infrastructure do
  use Boundary,
    deps: [
      ArmchairMetropolist.Domain,
      ArmchairMetropolist.UseCases,
      Ecto,
      Ecto.Query,
      Ecto.Changeset,
      Ecto.Schema,
      Phoenix.PubSub
    ],
    exports: [Simulation.CityEngine, Persistence.Repo]
end
```

`ExTauri` is deliberately **absent** until Task 11 — adding a boundary dep on a module from an
uninstalled dependency is a compile error.

In `lib/armchair_metropolist_web.ex`, inside the top `defmodule ArmchairMetropolistWeb do` block, before `def static_paths`:

```elixir
use Boundary,
  deps: [
    ArmchairMetropolist.Domain,
    ArmchairMetropolist.UseCases,
    ArmchairMetropolist.Infrastructure,
    Phoenix,
    Phoenix.LiveView,
    Phoenix.PubSub
  ],
  exports: [Endpoint, Telemetry]
```

In `lib/armchair_metropolist/application.ex`, after `use Application`:

```elixir
use Boundary,
  top_level?: true,
  deps: [
    ArmchairMetropolist.Domain,
    ArmchairMetropolist.Domain.Services,
    ArmchairMetropolist.UseCases,
    ArmchairMetropolist.Infrastructure,
    ArmchairMetropolistWeb
  ]
```

- [ ] **Step 6: Configure adapter injection**

In `config/config.exs`:

```elixir
config :armchair_metropolist,
  snapshot_repository: ArmchairMetropolist.Infrastructure.Persistence.SnapshotStore,
  notifier: ArmchairMetropolist.Infrastructure.Desktop.LogNotifier,
  grid_width: 40,
  grid_height: 30,
  tick_interval_ms: 1000,
  checkpoint_every_ticks: 50
```

- [ ] **Step 7: Verify the guardrail is armed**

Run: `mix compile --force --warnings-as-errors`
Expected: PASS, no `forbidden reference` warnings.

Then prove the enforcement bites — temporarily add to `simulation_calculator.ex`:

```elixir
def bad, do: Ecto.Changeset.cast({%{}, %{}}, %{}, [])
```

Run: `mix compile --force`
Expected: `warning: forbidden reference to Ecto.Changeset`. **Remove the line.** Do not proceed until this warning has been observed — an unarmed guardrail is worse than none, because it reads as protection.

Run: `mix boundary.spec` and confirm five boundaries are listed.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat: scaffold hexagonal boundaries and relocate Repo"
```

---

## Task 2: `Node` entity

**Spec:** §4.1, §4.2, §4.3 (status thresholds), §10.2

**Files:**
- Modify: `lib/armchair_metropolist/domain/entities/node.ex`
- Test: `test/armchair_metropolist/domain/entities/node_test.exs`

**Interfaces:**
- Consumes: the `Node` struct skeleton from Task 1.
- Produces:
  - `new(x :: non_neg_integer(), y :: non_neg_integer(), type :: node_type()) :: t()`
  - `id(x, y) :: String.t()` — `"#{x}:#{y}"`
  - `production(node_type()) :: %{resource() => float()}`
  - `consumption(node_type()) :: %{resource() => float()}`
  - `status_for(health :: float()) :: status()`
  - `display_signature(t()) :: {integer(), status()}`
  - `types() :: [node_type()]` — all seven, for tests and the UI picker
  - `effective_production(t()) :: %{resource() => float()}` — production scaled by `health / 100`

- [ ] **Step 1: Write the failing test**

`test/armchair_metropolist/domain/entities/node_test.exs`:

```elixir
defmodule ArmchairMetropolist.Domain.Entities.NodeTest do
  use ExUnit.Case, async: true

  alias ArmchairMetropolist.Domain.Entities.Node

  describe "new/3" do
    test "starts at full health and online" do
      node = Node.new(12, 7, :power_plant)
      assert node.id == "12:7"
      assert node.x == 12 and node.y == 7
      assert node.type == :power_plant
      assert node.health == 100.0
      assert node.status == :online
    end
  end

  describe "types/0" do
    test "lists all seven node types" do
      assert Enum.sort(Node.types()) ==
               Enum.sort([
                 :power_plant,
                 :water_plant,
                 :industrial,
                 :road_hub,
                 :residential,
                 :commercial,
                 :park
               ])
    end
  end

  describe "production/1 and consumption/1" do
    test "match the specified supply/demand table" do
      assert Node.production(:power_plant) == %{power: 120.0}
      assert Node.consumption(:power_plant) == %{water: 20.0, waste: 12.0, traffic: 3.0}

      assert Node.production(:water_plant) == %{water: 100.0}
      assert Node.consumption(:water_plant) == %{power: 25.0, waste: 6.0, traffic: 2.0}

      assert Node.production(:industrial) == %{waste: 90.0}
      assert Node.consumption(:industrial) == %{power: 40.0, water: 25.0, traffic: 8.0}

      assert Node.production(:road_hub) == %{traffic: 60.0}
      assert Node.consumption(:road_hub) == %{power: 8.0, waste: 2.0}

      assert Node.production(:residential) == %{}

      assert Node.consumption(:residential) == %{
               power: 15.0,
               water: 12.0,
               waste: 10.0,
               traffic: 6.0
             }

      assert Node.production(:commercial) == %{}

      assert Node.consumption(:commercial) == %{
               power: 22.0,
               water: 8.0,
               waste: 14.0,
               traffic: 9.0
             }

      assert Node.production(:park) == %{waste: 8.0}
      assert Node.consumption(:park) == %{water: 18.0, traffic: 2.0}
    end

    # Guards the invariant SimulationCalculator's decay rule depends on:
    # worst_ratio is Enum.min over consumed resources, which raises on an
    # empty list. If a future node type consumes nothing, this fails first.
    test "every node type consumes at least one resource" do
      for type <- Node.types() do
        assert map_size(Node.consumption(type)) > 0,
               "#{type} consumes nothing, which would break worst-ratio computation"
      end
    end
  end

  describe "status_for/1" do
    test "uses half-open intervals at the boundaries" do
      assert Node.status_for(100.0) == :online
      assert Node.status_for(60.0) == :online
      assert Node.status_for(59.9) == :degraded
      assert Node.status_for(20.0) == :degraded
      assert Node.status_for(19.9) == :offline
      assert Node.status_for(0.0) == :offline
    end
  end

  describe "display_signature/1" do
    test "is rounded health paired with status" do
      node = %Node{Node.new(1, 1, :park) | health: 87.3, status: :online}
      assert Node.display_signature(node) == {87, :online}
    end

    test "ignores sub-integer health movement" do
      # 87.6 and 87.9 both round to 88. (87.3 and 87.8 do NOT - they round to
      # 87 and 88 - so do not use those values here.)
      a = %Node{Node.new(1, 1, :park) | health: 87.6, status: :online}
      b = %Node{Node.new(1, 1, :park) | health: 87.9, status: :online}
      assert Node.display_signature(a) == Node.display_signature(b)
      assert Node.display_signature(a) == {88, :online}
    end

    test "uses round/1, not trunc/1" do
      # trunc(87.9) == 87 while round(87.9) == 88. This test exists because an
      # implementation using trunc, or snapping to the status thresholds, would
      # satisfy every other assertion here while corrupting delta membership
      # near the :degraded/:offline boundaries.
      node = %Node{Node.new(1, 1, :park) | health: 87.9, status: :online}
      assert Node.display_signature(node) == {88, :online}
    end

    test "distinguishes a status flip at identical rounded health" do
      a = %Node{Node.new(1, 1, :park) | health: 60.0, status: :online}
      b = %Node{Node.new(1, 1, :park) | health: 59.6, status: :degraded}
      assert {60, :online} = Node.display_signature(a)
      assert {60, :degraded} = Node.display_signature(b)
      refute Node.display_signature(a) == Node.display_signature(b)
    end
  end

  describe "effective_production/1" do
    test "scales production by health fraction" do
      node = %Node{Node.new(0, 0, :power_plant) | health: 50.0}
      assert effective = Node.effective_production(node)
      assert_in_delta effective.power, 60.0, 0.001
    end

    test "a near-dead plant produces almost nothing" do
      node = %Node{Node.new(0, 0, :power_plant) | health: 5.0}
      assert_in_delta Node.effective_production(node).power, 6.0, 0.001
    end

    test "consumers have no production at any health" do
      node = %Node{Node.new(0, 0, :residential) | health: 100.0}
      assert Node.effective_production(node) == %{}
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/armchair_metropolist/domain/entities/node_test.exs`
Expected: FAIL — `function Node.new/3 is undefined or private`

- [ ] **Step 3: Implement `Node`**

Fill in the module. Use module attributes for the tables so they are compile-time constants; derive `types/0` from the table keys so the two can never drift.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/armchair_metropolist/domain/entities/node_test.exs`
Expected: PASS

- [ ] **Step 5: Verify purity still holds**

Run: `mix compile --force --warnings-as-errors`
Expected: PASS with no `forbidden reference`.

- [ ] **Step 6: Commit**

```bash
git add lib/armchair_metropolist/domain/entities/node.ex test/armchair_metropolist/domain/entities/node_test.exs
git commit -m "feat: implement Node entity with resource tables and display signature"
```

---

## Task 3: `CityMap` entity

**Spec:** §4.1, §10.3

**Files:**
- Modify: `lib/armchair_metropolist/domain/entities/city_map.ex`
- Test: `test/armchair_metropolist/domain/entities/city_map_test.exs`

**Interfaces:**
- Consumes: `Node.new/3`, `Node.id/2` (Task 2).
- Produces:
  - `new(width :: pos_integer(), height :: pos_integer()) :: t()`
  - `in_bounds?(t(), x :: integer(), y :: integer()) :: boolean()`
  - `get_node(t(), x :: integer(), y :: integer()) :: Node.t() | nil`
  - `occupied?(t(), x :: integer(), y :: integer()) :: boolean()`
  - `put_node(t(), Node.t()) :: t()`
  - `delete_node(t(), x :: integer(), y :: integer()) :: t()`
  - `nodes(t()) :: [Node.t()]`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule ArmchairMetropolist.Domain.Entities.CityMapTest do
  use ExUnit.Case, async: true

  alias ArmchairMetropolist.Domain.Entities.{CityMap, Node}

  describe "new/2" do
    test "creates an empty grid at tick zero" do
      map = CityMap.new(40, 30)
      assert map.width == 40
      assert map.height == 30
      assert map.tick == 0
      assert map.nodes == %{}
    end
  end

  describe "in_bounds?/3" do
    setup do: {:ok, map: CityMap.new(40, 30)}

    test "accepts both corners", %{map: map} do
      assert CityMap.in_bounds?(map, 0, 0)
      assert CityMap.in_bounds?(map, 39, 29)
    end

    test "rejects every off-grid direction", %{map: map} do
      refute CityMap.in_bounds?(map, -1, 0)
      refute CityMap.in_bounds?(map, 0, -1)
      refute CityMap.in_bounds?(map, 40, 0)
      refute CityMap.in_bounds?(map, 0, 30)
    end
  end

  describe "placement and removal" do
    setup do: {:ok, map: CityMap.new(40, 30)}

    test "put_node/2 stores the node under its id", %{map: map} do
      node = Node.new(3, 4, :residential)
      map = CityMap.put_node(map, node)
      assert CityMap.get_node(map, 3, 4) == node
      assert CityMap.occupied?(map, 3, 4)
    end

    test "get_node/3 returns nil for an empty cell", %{map: map} do
      assert CityMap.get_node(map, 3, 4) == nil
      refute CityMap.occupied?(map, 3, 4)
    end

    test "delete_node/3 removes only the target", %{map: map} do
      map =
        map
        |> CityMap.put_node(Node.new(3, 4, :residential))
        |> CityMap.put_node(Node.new(5, 6, :park))
        |> CityMap.delete_node(3, 4)

      refute CityMap.occupied?(map, 3, 4)
      assert CityMap.occupied?(map, 5, 6)
      assert map_size(map.nodes) == 1
    end

    test "nodes/1 lists placed nodes", %{map: map} do
      map = CityMap.put_node(map, Node.new(1, 1, :park))
      assert [%Node{type: :park}] = CityMap.nodes(map)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/armchair_metropolist/domain/entities/city_map_test.exs`
Expected: FAIL — `CityMap.new/2 is undefined`

- [ ] **Step 3: Implement `CityMap`**

Key detail: `in_bounds?/3` must reject negatives explicitly — `Map.has_key?` on a computed id would not catch `-1`, and `"−1:0"` is a perfectly valid map key.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/armchair_metropolist/domain/entities/city_map_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/armchair_metropolist/domain/entities/city_map.ex test/armchair_metropolist/domain/entities/city_map_test.exs
git commit -m "feat: implement CityMap entity with bounds checking"
```

---

## Task 4: `SimulationMetrics` entity

**Spec:** §4.1, §10.4

**Files:**
- Modify: `lib/armchair_metropolist/domain/entities/simulation_metrics.ex`
- Test: `test/armchair_metropolist/domain/entities/simulation_metrics_test.exs`

**Interfaces:**
- Consumes: `Node`, `CityMap` (Tasks 2–3).
- Produces: `build(CityMap.t(), resources :: %{atom() => resource_stats()}) :: t()`

Resource stats are computed by `SimulationCalculator` (Task 5) and passed in; this module aggregates node-level figures only. That split keeps the supply/demand maths in one place.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule ArmchairMetropolist.Domain.Entities.SimulationMetricsTest do
  use ExUnit.Case, async: true

  alias ArmchairMetropolist.Domain.Entities.{CityMap, Node, SimulationMetrics}

  defp stats, do: %{power: %{supplied: 1.0, demanded: 1.0, deficit: 0.0, satisfaction: 1.0}}

  test "aggregates node count, average health and offline count" do
    map =
      CityMap.new(40, 30)
      |> CityMap.put_node(%Node{Node.new(0, 0, :residential) | health: 100.0, status: :online})
      |> CityMap.put_node(%Node{Node.new(1, 0, :residential) | health: 50.0, status: :degraded})
      |> CityMap.put_node(%Node{Node.new(2, 0, :residential) | health: 10.0, status: :offline})

    metrics = SimulationMetrics.build(%CityMap{map | tick: 7}, stats())

    assert metrics.tick == 7
    assert metrics.node_count == 3
    assert_in_delta metrics.avg_health, 53.3333, 0.001
    assert metrics.offline_count == 1
    assert metrics.resources == stats()
  end

  # An empty grid is the default startup state (spec 6.4 hydration fallback),
  # so avg_health must not divide by zero.
  test "an empty city yields zero average health rather than raising" do
    metrics = SimulationMetrics.build(CityMap.new(40, 30), stats())
    assert metrics.node_count == 0
    # === not ==, because 0 == 0.0 is true in Elixir. With ==, this assertion
    # passes even if the empty-city guard returns integer 0, leaving the
    # float requirement with no test behind it.
    assert metrics.avg_health === 0.0
    assert metrics.offline_count == 0
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/armchair_metropolist/domain/entities/simulation_metrics_test.exs`
Expected: FAIL — `SimulationMetrics.build/2 is undefined`

- [ ] **Step 3: Implement `build/2`**

Guard the empty case before dividing.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/armchair_metropolist/domain/entities/simulation_metrics_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/armchair_metropolist/domain/entities/simulation_metrics.ex test/armchair_metropolist/domain/entities/simulation_metrics_test.exs
git commit -m "feat: implement SimulationMetrics aggregation"
```

---

## Task 5: `SimulationCalculator` — the simulation core

**Spec:** §4.2 (baseline capacity), §4.3 (decay model), §4.4 (delta semantics), §10.5

This is the largest and most important task. Read §4.2–4.4 in full before starting.

**Files:**
- Modify: `lib/armchair_metropolist/domain/services/simulation_calculator.ex`
- Test: `test/armchair_metropolist/domain/services/simulation_calculator_test.exs`

**Interfaces:**
- Consumes: `Node.effective_production/1`, `Node.consumption/1`, `Node.status_for/1`, `Node.display_signature/1`, `CityMap`, `SimulationMetrics.build/2`.
- Produces:
  - `advance_tick(CityMap.t()) :: {CityMap.t(), delta :: %{String.t() => Node.t()}}`
  - `resource_stats(CityMap.t()) :: %{Node.resource() => SimulationMetrics.resource_stats()}`
  - `baseline_capacity() :: %{Node.resource() => float()}`
  - `metrics(CityMap.t()) :: SimulationMetrics.t()`

**Algorithm (implement exactly):**

1. `supply(r) = baseline_capacity[r] + Σ effective_production(node)[r]` over all nodes.
2. `demand(r) = Σ consumption(node.type)[r]` over all nodes — **not** scaled by health.
3. `satisfaction(r) = if demand == 0, do: 1.0, else: min(1.0, supply / demand)`.
4. For each node: `worst = Enum.min(for r <- Map.keys(consumption(node.type)), do: satisfaction[r])`.
5. `delta_health = if worst >= 1.0, do: +1.0, else: -(1.0 - worst) * 6.0`.
6. `health' = clamp(health + delta_health, 0.0, 100.0)`; `status' = Node.status_for(health')`.
7. `tick' = tick + 1`.
8. `delta` contains a node iff `display_signature(before) != display_signature(after)`.

Resource stats are computed **once from the pre-tick map** and applied to all nodes, so within a tick every node sees the same conditions. Do not recompute per node.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule ArmchairMetropolist.Domain.Services.SimulationCalculatorTest do
  use ExUnit.Case, async: true

  alias ArmchairMetropolist.Domain.Entities.{CityMap, Node}
  alias ArmchairMetropolist.Domain.Services.SimulationCalculator, as: Calc

  defp map_with(nodes) do
    Enum.reduce(nodes, CityMap.new(40, 30), &CityMap.put_node(&2, &1))
  end

  # Two residential blocks are sustainable on baseline capacity alone
  # (spec 4.2): power 30 <= 40, water 24 <= 40, waste 20 <= 40, traffic 12 <= 40.
  defp sustainable_city do
    map_with([Node.new(0, 0, :residential), Node.new(1, 0, :residential)])
  end

  describe "baseline_capacity/0" do
    test "supplies 40 of every resource" do
      assert Calc.baseline_capacity() == %{power: 40.0, water: 40.0, waste: 40.0, traffic: 40.0}
    end
  end

  describe "resource_stats/1" do
    test "satisfaction is capped at 1.0 on surplus" do
      stats = Calc.resource_stats(sustainable_city())
      assert stats.power.satisfaction == 1.0
      assert stats.power.deficit == 0.0
    end

    test "satisfaction is the ratio on shortfall, and deficit is the gap" do
      # Four residential: power demand 60 vs baseline supply 40.
      map = map_with(for x <- 0..3, do: Node.new(x, 0, :residential))
      stats = Calc.resource_stats(map)
      assert_in_delta stats.power.supplied, 40.0, 0.001
      assert_in_delta stats.power.demanded, 60.0, 0.001
      assert_in_delta stats.power.deficit, 20.0, 0.001
      assert_in_delta stats.power.satisfaction, 40.0 / 60.0, 0.001
    end

    test "satisfaction is 1.0 when nothing demands the resource" do
      stats = Calc.resource_stats(CityMap.new(40, 30))
      assert stats.power.satisfaction == 1.0
      assert stats.power.demanded == 0.0
    end

    test "includes baseline capacity in supply" do
      stats = Calc.resource_stats(CityMap.new(40, 30))
      assert_in_delta stats.power.supplied, 40.0, 0.001
    end

    test "production scales with health but consumption does not" do
      # This asymmetry is the mechanism behind cascading failure. If
      # consumption also scaled, the simulation would silently self-stabilise
      # and the cascade test below would pass for the wrong reason.
      healthy = map_with([%Node{Node.new(0, 0, :power_plant) | health: 100.0}])
      broken = map_with([%Node{Node.new(0, 0, :power_plant) | health: 50.0}])

      assert_in_delta Calc.resource_stats(healthy).power.supplied, 160.0, 0.001
      assert_in_delta Calc.resource_stats(broken).power.supplied, 100.0, 0.001

      # A power plant consumes water 20 regardless of its own condition.
      assert_in_delta Calc.resource_stats(healthy).water.demanded, 20.0, 0.001
      assert_in_delta Calc.resource_stats(broken).water.demanded, 20.0, 0.001
    end
  end

  describe "advance_tick/1 health arithmetic" do
    test "increments the tick by exactly one" do
      {map, _} = Calc.advance_tick(CityMap.new(40, 30))
      assert map.tick == 1
    end

    test "regenerates by 1.0 when fully supplied" do
      map = map_with([%Node{Node.new(0, 0, :residential) | health: 50.0, status: :degraded}])
      {map, _} = Calc.advance_tick(map)
      assert_in_delta CityMap.get_node(map, 0, 0).health, 51.0, 0.001
    end

    test "decays proportionally to the unmet fraction" do
      # 4 residential: power satisfaction 40/60 = 0.6667, worst across
      # resources. delta = -(1 - 0.6667) * 6.0 = -2.0
      map = map_with(for x <- 0..3, do: Node.new(x, 0, :residential))
      {map, _} = Calc.advance_tick(map)
      assert_in_delta CityMap.get_node(map, 0, 0).health, 98.0, 0.01
    end

    test "clamps at 100.0 and never exceeds it" do
      map = sustainable_city()
      {map, _} = Calc.advance_tick(map)
      assert CityMap.get_node(map, 0, 0).health == 100.0
    end

    test "clamps at 0.0 and never goes negative" do
      # Total starvation: satisfaction 0 gives delta -6.0 per tick.
      map = map_with([%Node{Node.new(0, 0, :residential) | health: 1.0, status: :offline}])
      # Force a hard deficit by adding heavy consumers with no producers.
      map = Enum.reduce(1..30, map, &CityMap.put_node(&2, Node.new(&1, 5, :commercial)))
      {map, _} = Calc.advance_tick(map)
      assert CityMap.get_node(map, 0, 0).health == 0.0
    end

    test "worst ratio considers only resources the node consumes" do
      # A park consumes water and traffic but no power, so a total blackout
      # must leave it untouched.
      park = %Node{Node.new(0, 0, :park) | health: 80.0, status: :online}
      power_hogs = for x <- 1..10, do: Node.new(x, 1, :commercial)
      # Add water and traffic capacity so only power is short.
      supply = [Node.new(0, 5, :water_plant), Node.new(1, 5, :road_hub)]
      map = map_with([park | power_hogs] ++ supply)

      stats = Calc.resource_stats(map)
      assert stats.power.satisfaction < 1.0, "test setup should starve power"

      {map, _} = Calc.advance_tick(map)
      assert CityMap.get_node(map, 0, 0).health >= 80.0
    end

    test "derives status from the new health" do
      map = map_with([%Node{Node.new(0, 0, :residential) | health: 60.4, status: :online}])
      # Starve it hard so health drops below 60.
      map = Enum.reduce(1..30, map, &CityMap.put_node(&2, Node.new(&1, 5, :commercial)))
      {map, _} = Calc.advance_tick(map)
      node = CityMap.get_node(map, 0, 0)
      assert node.health < 60.0
      assert node.status == :degraded
    end

    test "is order-independent" do
      # NOT `advance_tick(map) == advance_tick(map)` — that is a tautology for any
      # pure function and cannot fail. What matters is that resource stats are
      # computed once from the pre-tick map rather than per node, so insertion
      # order must not affect the result.
      nodes = for x <- 0..5, do: Node.new(x, 0, :residential)
      {a, _} = Calc.advance_tick(map_with(nodes))
      {b, _} = Calc.advance_tick(map_with(Enum.reverse(nodes)))
      assert Map.equal?(a.nodes, b.nodes)
    end

    test "cascading failure: a failing plant drags the city down with it" do
      # One power plant supporting more load than baseline can carry.
      plant = %Node{Node.new(0, 0, :power_plant) | health: 30.0, status: :degraded}
      consumers = for x <- 1..8, do: Node.new(x, 0, :residential)
      support = [Node.new(0, 2, :water_plant), Node.new(1, 2, :industrial), Node.new(2, 2, :road_hub)]
      initial = map_with([plant | consumers] ++ support)

      final =
        Enum.reduce(1..10, initial, fn _, acc ->
          {next, _delta} = Calc.advance_tick(acc)
          next
        end)

      plant_before = CityMap.get_node(initial, 0, 0).health
      plant_after = CityMap.get_node(final, 0, 0).health
      assert plant_after < plant_before, "the failing plant should keep degrading"

      consumer_after = CityMap.get_node(final, 1, 0).health
      assert consumer_after < 100.0, "consumers should degrade as supply collapses"

      assert Calc.resource_stats(final).power.satisfaction <
               Calc.resource_stats(initial).power.satisfaction,
             "power satisfaction should worsen as the plant decays"
    end
  end

  describe "advance_tick/1 delta semantics" do
    test "a stable, fully-supplied city emits an empty delta" do
      # Both nodes sit at 100.0 with full satisfaction, so health is clamped
      # and no display signature changes. This is the payoff of comparing
      # display state rather than raw structs.
      {_map, delta} = Calc.advance_tick(sustainable_city())
      assert delta == %{}
    end

    test "a starved city emits only the starved nodes" do
      starving = for x <- 0..3, do: Node.new(x, 0, :residential)
      # A park is insulated from the power shortage and should stay out.
      map = map_with([Node.new(0, 9, :park), Node.new(1, 9, :water_plant) | starving])
      {_map, delta} = Calc.advance_tick(map)

      assert Map.has_key?(delta, "0:0")
      refute Map.has_key?(delta, "0:9"), "the park does not consume power and should not change"
    end

    test "excludes a node whose health moves within the same rounded value" do
      # THE critical test: a health change too small to alter the rounded
      # display value must not enter the delta. A naive struct comparison
      # would include it and emit a full-grid delta every tick.
      #
      # Constructed via partial starvation so the decay is fractional.
      # 5 residential: power demand 75 vs baseline supply 40,
      # satisfaction 0.5333, delta = -(1 - 0.5333) * 6.0 = -2.8
      # A node at 90.4 goes to 87.6: round 90 -> 88, which DOES change.
      # So instead pick a starting health where the post-tick value rounds
      # identically. With decay -2.8, no single tick can round-trip; the
      # sub-rounding case therefore needs a gentler deficit.
      #
      # 5 residential + 1 power plant: power supply 40 + 120 = 160,
      # demand 75 + 0 = 75 -> power satisfied. Waste: supply 40,
      # demand 5*10 + 12 = 62, satisfaction 0.6452,
      # delta = -(1 - 0.6452) * 6.0 = -2.13. Still integral-crossing.
      #
      # Rather than contort the fixture, assert the property directly on
      # display_signature/1, which is what the delta membership rule uses.
      a = %Node{Node.new(0, 0, :residential) | health: 87.6, status: :online}
      b = %Node{a | health: 87.9}

      assert Node.display_signature(a) == Node.display_signature(b),
             "round(87.6) == round(87.9) == 88, so this movement must not enter the delta"

      # And prove the rule is actually what advance_tick/1 applies: a city
      # already clamped at 100.0 with full supply changes no signature.
      {_map, delta} = Calc.advance_tick(sustainable_city())
      assert delta == %{}
    end

    test "includes a node whose status flips at unchanged rounded health" do
      a = %Node{Node.new(0, 0, :residential) | health: 60.0, status: :online}
      b = %Node{a | health: 59.7, status: :degraded}
      assert Node.display_signature(a) != Node.display_signature(b)
    end

    test "delta keys are always a subset of the city's nodes" do
      map = map_with(for x <- 0..5, do: Node.new(x, 0, :residential))
      {new_map, delta} = Calc.advance_tick(map)
      assert MapSet.subset?(MapSet.new(Map.keys(delta)), MapSet.new(Map.keys(new_map.nodes)))
    end
  end

  describe "metrics/1" do
    test "reports tick, counts and resource stats together" do
      metrics = Calc.metrics(%CityMap{sustainable_city() | tick: 4})
      assert metrics.tick == 4
      assert metrics.node_count == 2
      assert metrics.resources.power.satisfaction == 1.0
    end
  end
end
```

> **Note for the implementer — this is REQUIRED, not optional.** A direct `display_signature`
> assertion is not sufficient on its own: a naive whole-struct comparison
> (`if node == advanced`) passes every other delta test in this file, because those fixtures
> use cities clamped at 100.0 where the struct is byte-identical anyway. You MUST add a
> fixture that produces a genuine sub-rounding health movement, or the single most important
> behaviour in this module has no test that can fail.
>
> A working fixture (verify the arithmetic yourself against the real tables and adjust if
> needed): `:power_plant` at `health: 90.0`, `:water_plant` at `health: 30.3`, and three
> `:park` nodes. Water demand is 20 + 54 = 74 against supply 40 + 30.3 = 70.3, giving
> satisfaction ≈ 0.95 while power, waste and traffic stay fully satisfied. The power plant's
> health delta is ≈ −0.30, so `90.0 → 89.7` — and `round(90.0) == round(89.7) == 90` with
> status unchanged, so it must be **excluded** from the delta despite its health moving.
>
> Before committing, confirm the test discriminates: temporarily swap the membership check for
> `if node == advanced`, confirm your new test FAILS, then restore it.

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/armchair_metropolist/domain/services/simulation_calculator_test.exs`
Expected: FAIL — `Calc.baseline_capacity/0 is undefined`

- [ ] **Step 3: Implement `SimulationCalculator`**

Follow the eight algorithm steps above exactly. Compute `resource_stats/1` once per tick from the pre-tick map.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/armchair_metropolist/domain/services/simulation_calculator_test.exs`
Expected: PASS. If the cascade or clamp tests fail because the constructed cities are not starved enough, adjust the *test fixtures* to create a genuine deficit — never weaken the assertion.

- [ ] **Step 5: Verify purity**

Run: `mix compile --force --warnings-as-errors`
Expected: PASS, no `forbidden reference`.

- [ ] **Step 6: Commit**

```bash
git add lib/armchair_metropolist/domain/services/simulation_calculator.ex test/armchair_metropolist/domain/services/simulation_calculator_test.exs
git commit -m "feat: implement SimulationCalculator with health decay and state diffing"
```

---

## Task 6: Domain properties and purity enforcement

**Spec:** §3.3, §10.6, §10.7

**Files:**
- Create: `test/armchair_metropolist/domain/domain_properties_test.exs`
- Create: `test/armchair_metropolist/domain/domain_purity_test.exs`
- Create: `test/support/city_generators.ex`

**Interfaces:**
- Consumes: everything from Tasks 2–5.
- Produces: `ArmchairMetropolist.CityGenerators.city/0` and `.node_type/0` StreamData generators, reusable by later tests.

- [ ] **Step 1: Write the generators**

`test/support/city_generators.ex` (compiled in `:test` via the existing `elixirc_paths`):

```elixir
defmodule ArmchairMetropolist.CityGenerators do
  @moduledoc "StreamData generators for property-based domain tests."

  import StreamData

  alias ArmchairMetropolist.Domain.Entities.{CityMap, Node}

  def node_type, do: member_of(Node.types())

  def health, do: float(min: 0.0, max: 100.0)

  @doc "A city on a small grid with 0..12 nodes at distinct coordinates."
  def city do
    gen all width <- integer(4..12),
            height <- integer(4..12),
            coords <-
              uniq_list_of(tuple({integer(0..3), integer(0..3)}), max_length: 12),
            types <- list_of(node_type(), length: length(coords)),
            healths <- list_of(health(), length: length(coords)) do
      [coords, types, healths]
      |> Enum.zip()
      |> Enum.reduce(CityMap.new(width, height), fn {{x, y}, type, h}, acc ->
        node = %Node{Node.new(x, y, type) | health: h, status: Node.status_for(h)}
        CityMap.put_node(acc, node)
      end)
    end
  end
end
```

- [ ] **Step 2: Write the property test**

```elixir
defmodule ArmchairMetropolist.Domain.DomainPropertiesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ArmchairMetropolist.CityGenerators
  alias ArmchairMetropolist.Domain.Entities.Node
  alias ArmchairMetropolist.Domain.Services.SimulationCalculator, as: Calc

  property "health always stays within 0.0..100.0 across many ticks" do
    check all city <- CityGenerators.city(), ticks <- StreamData.integer(1..25) do
      final =
        Enum.reduce(1..ticks, city, fn _, acc ->
          {next, _} = Calc.advance_tick(acc)
          next
        end)

      for {_id, node} <- final.nodes do
        assert node.health >= 0.0
        assert node.health <= 100.0
      end
    end
  end

  property "delta contains exactly the nodes whose display signature changed" do
    check all city <- CityGenerators.city() do
      before_sigs = Map.new(city.nodes, fn {id, n} -> {id, Node.display_signature(n)} end)
      {after_map, delta} = Calc.advance_tick(city)
      after_sigs = Map.new(after_map.nodes, fn {id, n} -> {id, Node.display_signature(n)} end)

      expected =
        for {id, sig} <- after_sigs, Map.fetch!(before_sigs, id) != sig, into: MapSet.new(), do: id

      assert MapSet.new(Map.keys(delta)) == expected
    end
  end

  property "advance_tick is deterministic" do
    check all city <- CityGenerators.city() do
      assert Calc.advance_tick(city) == Calc.advance_tick(city)
    end
  end

  property "advance_tick neither creates nor destroys nodes, and tick increases" do
    check all city <- CityGenerators.city() do
      {next, _} = Calc.advance_tick(city)
      assert map_size(next.nodes) == map_size(city.nodes)
      assert Map.keys(next.nodes) |> Enum.sort() == Map.keys(city.nodes) |> Enum.sort()
      assert next.tick == city.tick + 1
    end
  end

  property "status is always consistent with health" do
    check all city <- CityGenerators.city() do
      {next, _} = Calc.advance_tick(city)

      for {_id, node} <- next.nodes do
        assert node.status == Node.status_for(node.health)
      end
    end
  end
end
```

- [ ] **Step 3: Write the purity test**

```elixir
defmodule ArmchairMetropolist.Domain.DomainPurityTest do
  @moduledoc """
  Closes the one gap `boundary` cannot: GenServer, Agent, Task and Process
  live in the :elixir application, which boundary treats as unconditionally
  allowed. Verified empirically — `type: :strict` with `deps: []` compiles
  those calls clean.

  Reads each Domain module's compiled BEAM imports table, so aliases,
  imports and macro-generated calls cannot evade it.
  """
  use ExUnit.Case, async: true

  @forbidden_modules [
    GenServer, Agent, Task, Supervisor, Process, Registry,
    :ets, :dets, :timer, :gen_server, :global
  ]
  @forbidden_prefixes ["Ecto", "Phoenix", "ExTauri", "Plug"]

  test "no Domain module reaches OTP, Ecto, or Phoenix" do
    beams = domain_beams()

    assert beams != [], "found no Domain beam files - is the app compiled?"

    violations =
      for beam <- beams,
          {mod, imports} = imports_of(beam),
          {called, fun, arity} <- imports,
          forbidden?(called),
          do: "#{inspect(mod)} -> #{inspect(called)}.#{fun}/#{arity}"

    assert violations == [],
           "Domain layer must stay pure. Violations:\n  " <> Enum.join(violations, "\n  ")
  end

  defp domain_beams do
    :code.lib_dir(:armchair_metropolist)
    |> Path.join("ebin/Elixir.ArmchairMetropolist.Domain*.beam")
    |> Path.wildcard()
  end

  defp imports_of(beam) do
    {:ok, {mod, [imports: imports]}} =
      :beam_lib.chunks(String.to_charlist(beam), [:imports])

    {mod, imports}
  end

  defp forbidden?(called) do
    called in @forbidden_modules or
      Enum.any?(@forbidden_prefixes, fn prefix ->
        String.starts_with?(inspect(called), prefix <> ".") or inspect(called) == prefix
      end)
  end
end
```

- [ ] **Step 4: Run the tests**

Run: `mix test test/armchair_metropolist/domain/`
Expected: PASS.

- [ ] **Step 5: Prove the purity test bites**

Temporarily add `def bad(pid), do: GenServer.call(pid, :x)` to `simulation_calculator.ex`, run `mix test test/armchair_metropolist/domain/domain_purity_test.exs`, and confirm it FAILS naming `GenServer.call/2`. **Remove the line and re-run to green.** A purity test that cannot fail is worse than no test.

- [ ] **Step 6: Commit**

```bash
git add test/support/city_generators.ex test/armchair_metropolist/domain/
git commit -m "test: add domain property tests and BEAM-level purity enforcement"
```

---

## Task 7: Use cases

**Spec:** §5, §10.8

**Files:**
- Modify: `lib/armchair_metropolist/use_cases/advance_city_tick.ex`, `manage_infrastructure.ex`
- Test: `test/armchair_metropolist/use_cases/advance_city_tick_test.exs`, `manage_infrastructure_test.exs`

**Interfaces:**
- Consumes: `SimulationCalculator.advance_tick/1`, `.metrics/1`; `CityMap`; `Node.types/0`.
- Produces:
  - `AdvanceCityTick.execute(CityMap.t()) :: {:ok, %{city_map: CityMap.t(), delta: map(), metrics: SimulationMetrics.t()}}`
  - `ManageInfrastructure.place(CityMap.t(), integer(), integer(), atom()) :: {:ok, {CityMap.t(), Node.t()}} | {:error, :out_of_bounds | :occupied | :unknown_type}`
  - `ManageInfrastructure.demolish(CityMap.t(), integer(), integer()) :: {:ok, {CityMap.t(), String.t()}} | {:error, :empty}`

**These take no repository.** If you find yourself needing a test double, stop — orchestration and persistence have become tangled.

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule ArmchairMetropolist.UseCases.AdvanceCityTickTest do
  use ExUnit.Case, async: true

  alias ArmchairMetropolist.Domain.Entities.{CityMap, Node}
  alias ArmchairMetropolist.UseCases.AdvanceCityTick

  test "returns the new map, the delta and consistent metrics" do
    map =
      CityMap.new(40, 30)
      |> CityMap.put_node(Node.new(0, 0, :residential))
      |> CityMap.put_node(Node.new(1, 0, :residential))

    assert {:ok, %{city_map: next, delta: delta, metrics: metrics}} =
             AdvanceCityTick.execute(map)

    assert next.tick == 1
    assert metrics.tick == 1
    assert metrics.node_count == 2
    assert is_map(delta)
  end

  # An empty grid is the hydration fallback, so this is the startup path.
  test "advances an empty city without raising" do
    assert {:ok, %{city_map: next, delta: delta, metrics: metrics}} =
             AdvanceCityTick.execute(CityMap.new(40, 30))

    assert next.tick == 1
    assert delta == %{}
    assert metrics.avg_health == 0.0
  end
end
```

```elixir
defmodule ArmchairMetropolist.UseCases.ManageInfrastructureTest do
  use ExUnit.Case, async: true

  alias ArmchairMetropolist.Domain.Entities.{CityMap, Node}
  alias ArmchairMetropolist.UseCases.ManageInfrastructure

  setup do: {:ok, map: CityMap.new(40, 30)}

  describe "place/4" do
    test "places a healthy online node at the requested cell", %{map: map} do
      assert {:ok, {map, node}} = ManageInfrastructure.place(map, 3, 4, :power_plant)
      assert node.id == "3:4"
      assert node.health == 100.0
      assert node.status == :online
      assert CityMap.get_node(map, 3, 4) == node
    end

    test "rejects every out-of-bounds direction", %{map: map} do
      assert {:error, :out_of_bounds} = ManageInfrastructure.place(map, -1, 0, :park)
      assert {:error, :out_of_bounds} = ManageInfrastructure.place(map, 0, -1, :park)
      assert {:error, :out_of_bounds} = ManageInfrastructure.place(map, 40, 0, :park)
      assert {:error, :out_of_bounds} = ManageInfrastructure.place(map, 0, 30, :park)
    end

    test "rejects an occupied cell", %{map: map} do
      {:ok, {map, _}} = ManageInfrastructure.place(map, 3, 4, :park)
      assert {:error, :occupied} = ManageInfrastructure.place(map, 3, 4, :residential)
    end

    test "rejects an unknown node type", %{map: map} do
      assert {:error, :unknown_type} = ManageInfrastructure.place(map, 3, 4, :space_elevator)
    end

    test "leaves other nodes untouched", %{map: map} do
      {:ok, {map, first}} = ManageInfrastructure.place(map, 1, 1, :park)
      {:ok, {map, _}} = ManageInfrastructure.place(map, 2, 2, :residential)
      assert CityMap.get_node(map, 1, 1) == first
    end
  end

  describe "demolish/3" do
    test "removes the node and returns its id", %{map: map} do
      {:ok, {map, _}} = ManageInfrastructure.place(map, 3, 4, :park)
      assert {:ok, {map, "3:4"}} = ManageInfrastructure.demolish(map, 3, 4)
      refute CityMap.occupied?(map, 3, 4)
    end

    test "rejects a vacant cell", %{map: map} do
      assert {:error, :empty} = ManageInfrastructure.demolish(map, 3, 4)
    end

    test "removes exactly one node", %{map: map} do
      {:ok, {map, _}} = ManageInfrastructure.place(map, 1, 1, :park)
      {:ok, {map, _}} = ManageInfrastructure.place(map, 2, 2, :park)
      {:ok, {map, _}} = ManageInfrastructure.demolish(map, 1, 1)
      assert map_size(map.nodes) == 1
    end

    test "place then demolish round-trips to the original map", %{map: map} do
      {:ok, {placed, _}} = ManageInfrastructure.place(map, 5, 5, :industrial)
      {:ok, {restored, _}} = ManageInfrastructure.demolish(placed, 5, 5)
      assert restored == map
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/armchair_metropolist/use_cases/`
Expected: FAIL — undefined functions.

- [ ] **Step 3: Implement both use cases**

Validate in order: bounds, then type membership (`type in Node.types()`), then occupancy.

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/armchair_metropolist/use_cases/`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/armchair_metropolist/use_cases test/armchair_metropolist/use_cases
git commit -m "feat: implement AdvanceCityTick and ManageInfrastructure use cases"
```

---

## Task 8: Persistence adapters

**Spec:** §6.1, §6.2, §6.6, §10.9, §10.11

**Files:**
- Create: `priv/repo/migrations/20260729110000_create_city_snapshots.exs`
- Modify: `lib/armchair_metropolist/infrastructure/persistence/city_snapshot.ex`, `snapshot_store.ex`, `file_snapshot_store.ex`
- Create: `test/support/snapshot_repository_contract.ex`
- Test: `test/armchair_metropolist/infrastructure/persistence/snapshot_store_test.exs`, `file_snapshot_store_test.exs`

**Interfaces:**
- Consumes: `Domain.Ports.SnapshotRepository`, `CityMap`.
- Produces: two `@behaviour SnapshotRepository` modules, both with `load_latest/0` and `save/2`. `FileSnapshotStore` reads its directory from `Application.get_env(:armchair_metropolist, :snapshot_dir)`.

- [ ] **Step 1: Write the migration**

```elixir
defmodule ArmchairMetropolist.Infrastructure.Persistence.Repo.Migrations.CreateCitySnapshots do
  use Ecto.Migration

  def change do
    create table(:city_snapshots) do
      add :tick, :integer, null: false
      add :payload, :binary, null: false
      add :checksum, :string, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:city_snapshots, [:tick], name: :city_snapshots_tick_index)
  end
end
```

Run: `mix ecto.migrate` and `MIX_ENV=test mix ecto.migrate`.

- [ ] **Step 2: Write the shared contract**

`test/support/snapshot_repository_contract.ex` — a macro module so both adapters run identical assertions, proving they are interchangeable rather than merely intended to be:

```elixir
defmodule ArmchairMetropolist.SnapshotRepositoryContract do
  @moduledoc "Shared assertions every SnapshotRepository adapter must satisfy."

  defmacro __using__(adapter: adapter) do
    quote do
      alias ArmchairMetropolist.Domain.Entities.{CityMap, Node}

      @adapter unquote(adapter)

      defp sample_city do
        CityMap.new(40, 30)
        |> CityMap.put_node(Node.new(1, 1, :power_plant))
        |> CityMap.put_node(%Node{Node.new(2, 2, :residential) | health: 42.5, status: :degraded})
      end

      test "returns :not_found when nothing is stored" do
        assert {:error, :not_found} = @adapter.load_latest()
      end

      test "round-trips a city map" do
        city = sample_city()
        assert :ok = @adapter.save(7, city)
        assert {:ok, {7, loaded}} = @adapter.load_latest()
        assert loaded == city
      end

      test "returns the most recent snapshot" do
        assert :ok = @adapter.save(1, sample_city())
        assert :ok = @adapter.save(9, CityMap.new(10, 10))
        assert {:ok, {9, loaded}} = @adapter.load_latest()
        assert loaded.width == 10
      end

      test "save/2 returns bare :ok, not {:ok, id}" do
        assert :ok === @adapter.save(3, sample_city())
      end
    end
  end
end
```

The file is `.ex`, not `.exs`, so the existing `elixirc_paths(:test)` entry for `test/support` compiles it automatically — no `Code.require_file` needed.

- [ ] **Step 3: Write the adapter tests**

`snapshot_store_test.exs` uses the contract plus a corrupted-checksum case:

```elixir
defmodule ArmchairMetropolist.Infrastructure.Persistence.SnapshotStoreTest do
  use ArmchairMetropolist.DataCase, async: false

  alias ArmchairMetropolist.Infrastructure.Persistence.{CitySnapshot, Repo, SnapshotStore}

  use ArmchairMetropolist.SnapshotRepositoryContract, adapter: SnapshotStore

  test "detects a corrupted payload" do
    :ok = SnapshotStore.save(1, sample_city())

    Repo.one(CitySnapshot)
    |> Ecto.Changeset.change(checksum: "DEADBEEF")
    |> Repo.update!()

    assert {:error, :checksum_mismatch} = SnapshotStore.load_latest()
  end
end
```

`file_snapshot_store_test.exs`:

```elixir
defmodule ArmchairMetropolist.Infrastructure.Persistence.FileSnapshotStoreTest do
  use ExUnit.Case, async: false

  alias ArmchairMetropolist.Infrastructure.Persistence.FileSnapshotStore

  setup do
    dir = Path.join(System.tmp_dir!(), "acm_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    prev = Application.get_env(:armchair_metropolist, :snapshot_dir)
    Application.put_env(:armchair_metropolist, :snapshot_dir, dir)

    on_exit(fn ->
      File.rm_rf!(dir)
      Application.put_env(:armchair_metropolist, :snapshot_dir, prev)
    end)

    {:ok, dir: dir}
  end

  use ArmchairMetropolist.SnapshotRepositoryContract, adapter: FileSnapshotStore

  test "leaves no temp file behind after a successful save", %{dir: dir} do
    :ok = FileSnapshotStore.save(1, sample_city())
    refute File.exists?(Path.join(dir, "snapshot.tmp"))
    assert File.exists?(Path.join(dir, "snapshot.bin"))
  end

  test "falls back to the backup when the primary is corrupt", %{dir: dir} do
    :ok = FileSnapshotStore.save(1, sample_city())
    :ok = FileSnapshotStore.save(2, CityMap.new(12, 12))

    File.write!(Path.join(dir, "snapshot.bin"), "garbage")

    assert {:ok, {1, recovered}} = FileSnapshotStore.load_latest()
    assert recovered == sample_city()
  end

  test "returns :not_found when both files are unusable", %{dir: dir} do
    :ok = FileSnapshotStore.save(1, sample_city())
    :ok = FileSnapshotStore.save(2, CityMap.new(12, 12))
    File.write!(Path.join(dir, "snapshot.bin"), "garbage")
    File.write!(Path.join(dir, "snapshot.bak"), "also garbage")

    assert {:error, :not_found} = FileSnapshotStore.load_latest()
  end
end
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `mix test test/armchair_metropolist/infrastructure/persistence/`
Expected: FAIL — undefined functions.

- [ ] **Step 5: Implement `CitySnapshot`, `SnapshotStore`, `FileSnapshotStore`**

`CitySnapshot` — `schema "city_snapshots"` with `field :tick, :integer`, `field :payload, :binary`, `field :checksum, :string`, `timestamps(type: :utc_datetime_usec)`, and a `changeset/2` casting and requiring all three.

Both adapters share the encode/decode logic:
- encode: `payload = :erlang.term_to_binary(city_map, [:compressed])`, `checksum = :crypto.hash(:md5, payload) |> Base.encode16()`
- decode: recompute the MD5, compare, then `:erlang.binary_to_term(payload, [:safe])`

`FileSnapshotStore` writes `%{version: 1, tick: tick, checksum: checksum, payload: payload}` via `term_to_binary` (uncompressed — the payload is already compressed) to `snapshot.tmp`, moves any existing `snapshot.bin` to `snapshot.bak`, then `File.rename!/2` the tmp into place. `load_latest/0` tries `snapshot.bin` then `snapshot.bak`, rescuing any error from either.

- [ ] **Step 6: Run tests to verify they pass**

Run: `mix test test/armchair_metropolist/infrastructure/persistence/`
Expected: PASS — the contract block runs against both adapters.

- [ ] **Step 7: Commit**

```bash
git add priv/repo/migrations lib/armchair_metropolist/infrastructure/persistence test/support test/armchair_metropolist/infrastructure
git commit -m "feat: add Postgres and file snapshot adapters with shared contract test"
```

---

## Task 9: `TickServer` and `CityEngine`

**Spec:** §6.3, §6.4, §6.5, §6.7, §10.9

**Files:**
- Modify: `lib/armchair_metropolist/infrastructure/simulation/tick_server.ex`, `city_engine.ex`
- Modify: `lib/armchair_metropolist/infrastructure/desktop/log_notifier.ex`
- Modify: `lib/armchair_metropolist/application.ex`
- Create: `test/support/stub_snapshot_repository.ex`, `test/support/stub_notifier.ex`
- Test: `test/armchair_metropolist/infrastructure/simulation/tick_server_test.exs`, `city_engine_test.exs`

**Interfaces:**
- Consumes: `AdvanceCityTick.execute/1`, `ManageInfrastructure.place/4` and `.demolish/3`, both ports.
- Produces:
  - `TickServer.start_link(opts)` — broadcasts `{:tick, n}` on `"city_tick"`.
  - `CityEngine.start_link(opts)`, `.snapshot()` → `{:ok, %{city_map:, metrics:}}`, `.place(x, y, type)`, `.demolish(x, y)`.
  - Broadcasts on `"city_simulation"`: `{:city_delta, delta}`, `{:city_metrics, metrics}`, `{:city_node_placed, node}`, `{:city_node_removed, id}`.

**Critical details:**
- `init/1` must call `Process.flag(:trap_exit, true)` — without it `terminate/2` never runs and the shutdown-persistence guarantee is false.
- Hydrate in `handle_continue(:hydrate, state)`, **not** `init/1`, so a slow database cannot block the supervision tree.
- Child spec needs `shutdown: 10_000`; the 5s default can kill the process mid-write.
- Checkpoint when `tick > 0 and rem(tick, checkpoint_every_ticks) == 0`.
- Resolve both adapters at call time via `Application.get_env/3` so tests can inject stubs.

- [ ] **Step 1: Write the stubs**

An `Agent` is fine here — this is infrastructure, not domain, so the purity test does not apply.

`test/support/stub_snapshot_repository.ex`:

```elixir
defmodule ArmchairMetropolist.StubSnapshotRepository do
  @moduledoc "In-memory SnapshotRepository for engine tests."
  @behaviour ArmchairMetropolist.Domain.Ports.SnapshotRepository

  use Agent

  def start_link(_ \\ []) do
    Agent.start_link(fn -> %{initial: {:error, :not_found}, saves: []} end, name: __MODULE__)
  end

  @doc "Seed what load_latest/0 will return."
  def set_initial(result), do: Agent.update(__MODULE__, &%{&1 | initial: result})

  @doc "Every {tick, city_map} passed to save/2, newest first."
  def saves, do: Agent.get(__MODULE__, & &1.saves)

  @impl true
  def load_latest, do: Agent.get(__MODULE__, & &1.initial)

  @impl true
  def save(tick, city_map) do
    Agent.update(__MODULE__, &%{&1 | saves: [{tick, city_map} | &1.saves]})
    :ok
  end
end
```

`test/support/stub_notifier.ex` — routes notifications back to the test process. The pid is
held in application env because the port is called from inside the engine process, which has
no other channel to the test:

```elixir
defmodule ArmchairMetropolist.StubNotifier do
  @moduledoc "Forwards notifications to the pid in :notifier_test_pid."
  @behaviour ArmchairMetropolist.Domain.Ports.Notifier

  @impl true
  def notify(title, body) do
    case Application.get_env(:armchair_metropolist, :notifier_test_pid) do
      nil -> :ok
      pid -> send(pid, {:notified, title, body})
    end

    :ok
  end
end
```

- [ ] **Step 2: Write the failing tests**

`tick_server_test.exs`: subscribe to `"city_tick"`, start a `TickServer` with a 20ms interval, `assert_receive {:tick, 1}` then `{:tick, 2}`. Add a test asserting the clock keeps ticking when no engine is running — that is the whole point of the decoupling.

`city_engine_test.exs`, with `:snapshot_repository` and `:notifier` pointed at the stubs:
- hydrates from a seeded snapshot (assert `snapshot()` returns the seeded map and tick)
- falls back to a 40×30 empty grid when the repository returns `{:error, :not_found}`
- broadcasts `{:city_delta, delta}` and `{:city_metrics, metrics}` when a `{:tick, n}` arrives on `"city_tick"`
- `place/3` broadcasts `{:city_node_placed, node}`; `demolish/2` broadcasts `{:city_node_removed, id}`
- `place/3` on an occupied cell returns `{:error, :occupied}` and broadcasts nothing
- `terminate/2` persists: stop the engine with `GenServer.stop/1` and assert the stub recorded a save
- checkpoints at the configured interval (set `checkpoint_every_ticks: 2`, send three ticks, assert a save happened before shutdown)

Plus the notification behaviour required by spec §10.11 — set
`:notifier_test_pid` to `self()` and `:notifier` to `StubNotifier`, then:

```elixir
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
```

The engine therefore needs a `critical?` flag in its state, set when a deficit begins and
cleared when satisfaction recovers — notifying on every tick of a sustained blackout would be
unusable.

- [ ] **Step 3: Run tests to verify they fail**

Run: `mix test test/armchair_metropolist/infrastructure/simulation/`
Expected: FAIL

- [ ] **Step 4: Implement `LogNotifier`, `TickServer`, `CityEngine`**

Then update `Application.start/2` to build children from config:

```elixir
children =
  repo_children() ++
    [
      {Phoenix.PubSub, name: ArmchairMetropolist.PubSub},
      ArmchairMetropolistWeb.Telemetry,
      Supervisor.child_spec(ArmchairMetropolist.Infrastructure.Simulation.CityEngine,
        shutdown: 10_000
      ),
      ArmchairMetropolist.Infrastructure.Simulation.TickServer,
      ArmchairMetropolistWeb.Endpoint
    ]
```

where `repo_children/0` returns `[ArmchairMetropolist.Infrastructure.Persistence.Repo]` unless `Application.get_env(:armchair_metropolist, :start_repo, true)` is false — the desktop target sets it false, since the file adapter needs no database.

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/armchair_metropolist/infrastructure/simulation/`
Expected: PASS

- [ ] **Step 6: Full suite and boundary check**

Run: `mix check`
Expected: PASS, no `forbidden reference`.

- [ ] **Step 7: Commit**

```bash
git add lib test
git commit -m "feat: add TickServer clock and CityEngine with snapshot lifecycle"
```

---

## Task 10: `SimulatorLive` dashboard

**Spec:** §7, §10.10

**Files:**
- Create: `lib/armchair_metropolist_web/live/simulator_live.ex`
- Modify: `lib/armchair_metropolist_web/router.ex`
- Test: `test/armchair_metropolist_web/live/simulator_live_test.exs`

**Interfaces:**
- Consumes: `CityEngine.snapshot/0`, `.place/3`, `.demolish/2`; `Node`; the four `"city_simulation"` messages.
- Produces: a LiveView at `/`.

**Rendering strategy:** the 1,200 background cells are a plain comprehension — static, never re-diffed. Placed infrastructure lives in `stream(:nodes, ...)` with `dom_id: & &1.id`. Absolute-position each node over the grid so the two layers stay independent.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule ArmchairMetropolistWeb.SimulatorLiveTest do
  use ArmchairMetropolistWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ArmchairMetropolist.Domain.Entities.Node

  test "renders the grid and the type picker", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Armchair Metropolist"
    assert html =~ "power_plant"
  end

  test "a delta broadcast updates only the affected node", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    node = %Node{Node.new(4, 5, :power_plant) | health: 41.0, status: :degraded}
    Phoenix.PubSub.broadcast(
      ArmchairMetropolist.PubSub,
      "city_simulation",
      {:city_delta, %{"4:5" => node}}
    )

    assert render(view) =~ "4:5"
  end

  test "clicking a cell places infrastructure", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element(~s{[phx-click="place"][phx-value-x="2"][phx-value-y="3"]})
    |> render_click()

    assert render(view) =~ "2:3"
  end

  test "a removal broadcast deletes the node from the stream", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    node = Node.new(6, 6, :park)
    Phoenix.PubSub.broadcast(
      ArmchairMetropolist.PubSub,
      "city_simulation",
      {:city_node_placed, node}
    )
    assert render(view) =~ "6:6"

    Phoenix.PubSub.broadcast(
      ArmchairMetropolist.PubSub,
      "city_simulation",
      {:city_node_removed, "6:6"}
    )
    refute render(view) =~ ~s{id="6:6"}
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/armchair_metropolist_web/live/simulator_live_test.exs`
Expected: FAIL — no route.

- [ ] **Step 3: Implement `SimulatorLive` and route it**

In `mount/3`: subscribe to `"city_simulation"` when `connected?/1`, fetch `CityEngine.snapshot/0`, `stream(:nodes, ...)`, assign the selected type and metrics.

Handlers: `{:city_delta, delta}` → `stream_insert/3` per node; `{:city_metrics, m}` → assign; `{:city_node_placed, node}` → `stream_insert/3`; `{:city_node_removed, id}` → `stream_delete_by_dom_id(socket, :nodes, id)`.

Events: `"place"`, `"demolish"`, `"select_type"`.

Router: replace the generated `get "/", PageController, :home` with `live "/", SimulatorLive`.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/armchair_metropolist_web/live/simulator_live_test.exs`
Expected: PASS

- [ ] **Step 5: Full suite**

Run: `mix check`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/armchair_metropolist_web test/armchair_metropolist_web
git commit -m "feat: add SimulatorLive dashboard with stream-based diff rendering"
```

---

## Task 11: Desktop target

**Spec:** §6.6, §6.7, §8

Attempt only after Tasks 1–10 are green. This is the riskiest dependency (`ex_tauri` 0.2.0, released 2026-07-12, 138 downloads) and is deliberately last: a failure here leaves a working web application.

**Files:**
- Modify: `mix.exs`, `config/config.exs`, `config/runtime.exs`, `config/prod.exs`
- Modify: `lib/armchair_metropolist/infrastructure.ex` (add `ExTauri` to `deps`)
- Create: `lib/armchair_metropolist/infrastructure/desktop/tauri_notifier.ex`
- Whatever `mix ex_tauri.install` generates

- [ ] **Step 1: Install**

Add `{:ex_tauri, "~> 0.2"}`, `mix deps.get`, then `mix ex_tauri.install`. Review every file it touches with `git diff` before committing — it modifies the supervision tree, release config, layouts and JS.

- [ ] **Step 2: Configure**

```elixir
config :ex_tauri,
  version: "2.5.1",
  app_name: "Armchair Metropolist",
  host: "localhost",
  window_title: "Armchair Metropolist",
  width: 1280,
  height: 900,
  resize: true
```

Add `:inets` to `extra_applications`. Remove `cache_static_manifest` from `config/prod.exs` unless `mix assets.deploy` runs in the build.

Desktop overrides — repo off, file adapter on:

```elixir
config :armchair_metropolist,
  start_repo: false,
  snapshot_repository: ArmchairMetropolist.Infrastructure.Persistence.FileSnapshotStore,
  notifier: ArmchairMetropolist.Infrastructure.Desktop.TauriNotifier
```

In `config/runtime.exs`, set `:snapshot_dir` from `ExTauri.Paths.data_dir()`. Persistence must not call `ExTauri` itself.

- [ ] **Step 3: Add `ExTauri` to the Infrastructure boundary**

Only now — before the dependency exists, naming it is a compile error.

- [ ] **Step 4: Implement `TauriNotifier`**

Delegates to `ex_tauri`'s notification API, matching `LogNotifier`'s `@behaviour Notifier`.

- [ ] **Step 5: Verify in the native window**

Run: `mix ex_tauri.dev`
Expected: a native window; the grid renders; ticks advance; clicking places infrastructure.

- [ ] **Step 6: Verify the durability path — the test that matters most**

Close the window, then relaunch `mix ex_tauri.dev`. The city must be as you left it. This is the only check that exercises §8.3's heartbeat shutdown together with `terminate/2` and the file adapter end to end. If state is lost, check in this order: was `:trap_exit` set; was `shutdown: 10_000` applied; did `ExTauri.Paths.data_dir()` resolve to a writable path.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: wrap the app as a native desktop application via ex_tauri"
```

- [ ] **Step 8: Production build (optional, may be blocked)**

Add the Burrito release config from §8.4. `mix ex_tauri.build` requires an ERTS the CDN has built — our local OTP 29.0.4 returns 404, so pin the build toolchain to **28.4.2** (the only version with macOS *and* both Linux triples). If this proves difficult, stop and report: `mix ex_tauri.dev` working is the task's actual deliverable, and a blocked production build is a documented follow-up, not a failure of the design.

---

## Task 12: Coverage gate and final verification

**Files:** Modify `mix.exs`

- [ ] **Step 1: Measure current coverage**

Run: `mix test --cover`
Note the total percentage and which modules are below par.

- [ ] **Step 2: Close real gaps**

For any `Domain`, `Domain.Services` or `UseCases` line not covered, add the missing test. These layers are pure, so an uncovered line is an untested branch, not an untestable one. Do **not** lower the threshold to accommodate a gap in these three layers.

- [ ] **Step 3: Add the gate**

```elixir
test_coverage: [threshold: 90],
```

and update the alias to `check: ["compile --force --warnings-as-errors", "test --cover"]`.

- [ ] **Step 4: Verify**

Run: `mix check`
Expected: PASS.

- [ ] **Step 5: Confirm the enforced architecture**

Run: `mix boundary.spec`
Expected: five boundaries; `Domain` and `Domain.Services` with no external deps.

- [ ] **Step 6: Commit**

```bash
git add mix.exs
git commit -m "chore: gate coverage at 90% and finalise the check alias"
```

---

## Task Dependency Graph

```
1 Foundation  ──┬──> 2 Node ──┬──> 3 CityMap ──┐
                │             └──> 4 Metrics ──┴──> 5 Calculator ──┬──> 6 Properties+Purity
                │                                                  └──> 7 Use cases ──┬──> 9 Engine
                └──> 8 Persistence ────────────────────────────────────────────────────┘   │
                                                                                            └──> 10 LiveView ──> 11 Desktop ──> 12 Coverage
```

Tasks run **sequentially**. Parallel subagents would share one `_build` directory and thrash the same compile lock, so isolation here is per-task *context*, not wall-clock.
