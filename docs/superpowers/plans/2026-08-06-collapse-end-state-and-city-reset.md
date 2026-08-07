# Collapse End State and City Reset Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the simulation when a city is provably dead, and give the player a one-click reset that clears the grid and starts a new city.

**Architecture:** Three boolean facts land on `SimulationMetrics` (`stalled`, `housing_alive`, `bankrupt`) plus a `game_over?/1` function composing two of them. `CityEngine` ignores clock pulses while `stalled`, which freezes the city *and* preserves its treasury. The reset is a pure `CityMap.reset/1` wrapped in a `ResetCity` use case, plus a new `delete/1` callback on the snapshot port so a tick-0 city can be persisted without violating `save/3`'s monotonicity guarantee. The UI gains a header slot carrying a `Reset` button and a status banner above the grid.

**Tech Stack:** Elixir, Phoenix LiveView, Ecto/Postgres, `Boundary` for architectural layering, ExUnit, Tailwind v4 + daisyUI v5.

## Global Constraints

Copied verbatim from `docs/superpowers/specs/2026-08-06-collapse-end-state-and-city-reset-design.md`. Every task's requirements implicitly include this section.

- **Boundaries are compile-enforced.** `Domain` is `type: :strict, deps: []`. `Domain.Services` may depend on `Domain`. `UseCases` may depend on both. `Infrastructure` may depend on `Domain` and `UseCases` — **never** on `Domain.Services`. `ArmchairMetropolistWeb` may depend on `Domain`, `UseCases`, `Infrastructure`. A violation fails `mix compile --warnings-as-errors`.
- **Anything new that `Domain` must expose has to be added to its `exports:` list** in `lib/armchair_metropolist/domain.ex`. `Entities.CityMap`, `Entities.Node`, `Entities.SimulationMetrics`, `Ports.SnapshotRepository` and `Ports.Notifier` are already exported; **no new export is needed by this plan.**
- **No `SnapshotVocabulary` change and no snapshot migration.** Nothing this plan adds is stored: `SimulationMetrics` is recomputed on every hydration, and `CityMap` gains no field.
- **`save/3` stays monotonic in tick.** No force flag, no bypass. The only new way to move a city backwards is `delete/1`.
- **Reset is free and unconfirmed.** It charges nothing and has no confirmation dialog. This was decided explicitly; do not add one.
- **Button label is exactly `Reset`.** Button classes are exactly `btn btn-xs btn-error text-white min-h-6`. `min-h-6` (24px) satisfies WCAG 2.2's 24×24 target size, which bare `btn-xs` (21px) fails. `text-white` is required: daisyUI's own `--color-error-content` measures 4.08:1 against `--color-error`, below the 4.5 AA floor; white is 4.60:1.
- **Banner headlines are exactly** `Game over — this city is dead.` and `City stalled — nothing is changing on its own.` (em dash, trailing full stop). Both banners share their second sentence, so the headline is the only text distinguishing them.
- **Nothing goes inside the `<aside>`.** Its width sets the wrap thresholds documented at length in `SimulatorLive.render/1` (expanded 2335, collapsed 1415 with *zero slack*). Adding anything there invalidates measurements this plan does not re-take.
- **Run `mix precommit` before every commit** (`compile --warnings-as-errors`, `deps.unlock --unused`, `format`, `test`). `mix precommit` itself does not run Sobelow, but **the commit does**: this repo sets `core.hooksPath` to `.githooks`, and `.githooks/pre-commit` runs `mix sobelow` (line 85). Do not look in `.git/hooks` to check this — the redirect means that directory holds nothing but the stock `.sample` files, which reads as "no hooks" and is wrong. `.sobelow-conf` sets `exit: "low"`, so *any* unannotated finding blocks the commit. The one task that adds a flagged call is Task 6 (`File.rm`), and it runs `mix sobelow` explicitly so the failure surfaces at the verify step rather than at `git commit`.

---

## File Structure

**Created:**
- `lib/armchair_metropolist/use_cases/reset_city.ex` — pure use case: reset a city map and compute its metrics. Mirrors `AdvanceCityTick`.
- `test/armchair_metropolist/use_cases/reset_city_test.exs`

**Modified:**
- `lib/armchair_metropolist/domain/entities/node.ex` — `cheapest_construction_cost/0`, `cheapest_action_cost/0`.
- `lib/armchair_metropolist/domain/entities/city_map.ex` — `reset/1`.
- `lib/armchair_metropolist/domain/entities/simulation_metrics.ex` — `housing_alive`, `bankrupt`, `stalled` fields; `game_over?/1`; third `build/3` argument renamed `derived`.
- `lib/armchair_metropolist/domain/services/simulation_calculator.ex` — `stalled?/2`, passed through `metrics/1`.
- `lib/armchair_metropolist/domain/ports/snapshot_repository.ex` — `delete/1` callback.
- `lib/armchair_metropolist/infrastructure/persistence/snapshot_store.ex` — `delete/1`.
- `lib/armchair_metropolist/infrastructure/persistence/file_snapshot_store.ex` — `delete/1`.
- `lib/armchair_metropolist/infrastructure/simulation/city_engine.ex` — freeze clause, `reset/1`, `handle_call(:reset, …)`.
- `lib/armchair_metropolist_web/components/layouts.ex` — `slot :actions`, header group flex fix, wordmark grid.
- `lib/armchair_metropolist_web/live/simulator_live.ex` — banner, button, `wipe` event, `:city_reset` handler.
- `docs/PLAYING.md` — new section.
- Test doubles: `test/support/stub_snapshot_repository.ex`, `test/support/slow_snapshot_repository.ex`, `test/support/snapshot_repository_contract.ex`.

---

### Task 1: `Node` learns the cheapest costs

**Files:**
- Modify: `lib/armchair_metropolist/domain/entities/node.ex` (after `demolition_cost/0`, ~line 145)
- Test: `test/armchair_metropolist/domain/entities/node_test.exs`

**Interfaces:**
- Consumes: nothing.
- Produces: `Node.cheapest_construction_cost() :: float()` (15.0 today), `Node.cheapest_action_cost() :: float()` (10.0 today).

- [ ] **Step 1: Write the failing test**

Add a new `describe` block to `node_test.exs`, after the existing
`describe "construction_cost/1 and demolition_cost/0"` block (every test in that file
lives in a `describe`; there is no bare top-level block to append to). The file aliases
`ArmchairMetropolist.Domain.Entities.Node` already and needs nothing else:

```elixir
describe "cheapest costs" do
  test "cheapest_construction_cost is a real construction cost, and a lower bound on all of them" do
    costs = Enum.map(Node.types(), &Node.construction_cost/1)

    assert Node.cheapest_construction_cost() in costs
    assert Enum.all?(costs, &(Node.cheapest_construction_cost() <= &1))
  end

  test "cheapest_action_cost is a real action cost, and a lower bound on all of them" do
    # Characterised as "a member of the set, and <= every member" rather than by
    # restating `min(...)`. Restating the implementation's own expression would make
    # this test unable to fail.
    actions = [Node.demolition_cost() | Enum.map(Node.types(), &Node.construction_cost/1)]

    assert Node.cheapest_action_cost() in actions
    assert Enum.all?(actions, &(Node.cheapest_action_cost() <= &1))
  end

  test "today the cheapest action is the demolition fee, and the cheapest build is a house" do
    # Pins the figures the player-facing copy and the bankruptcy threshold quote.
    # The characterisations above hold for any table; these two are what change if
    # a balance patch moves the prices.
    assert Node.cheapest_action_cost() == 10.0
    assert Node.cheapest_construction_cost() == 15.0
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/armchair_metropolist/domain/entities/node_test.exs`
Expected: FAIL — `function ArmchairMetropolist.Domain.Entities.Node.cheapest_construction_cost/0 is undefined or private`

- [ ] **Step 3: Write minimal implementation**

In `node.ex`, immediately after `def demolition_cost, do: @demolition_cost`:

```elixir
  @doc """
  The cheapest block a player can put up.

  Derived from the table rather than written down again: the figure appears in the
  game-over copy, and a balance patch that reprices `residential` must move the
  sentence with it.
  """
  @spec cheapest_construction_cost() :: float()
  def cheapest_construction_cost, do: Enum.min(Map.values(@construction_cost_table))

  @doc """
  The cheapest thing a player can do at all — build the cheapest block, or demolish.

  This is the bankruptcy threshold: below it no command is affordable, so a frozen
  city holding less than this can never change again. Derived rather than pinned to
  `demolition_cost/0`, even though demolition is the cheaper of the two today and
  `node_test.exs` enforces that. Deriving means a balance patch that inverts them
  moves this figure too, instead of silently leaving a threshold naming the wrong
  lever.
  """
  @spec cheapest_action_cost() :: float()
  def cheapest_action_cost, do: min(@demolition_cost, cheapest_construction_cost())
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/armchair_metropolist/domain/entities/node_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
mix precommit
git add lib/armchair_metropolist/domain/entities/node.ex test/armchair_metropolist/domain/entities/node_test.exs
git commit -m "feat(domain): derive the cheapest construction and action costs"
```

---

### Task 2: `SimulationMetrics` gains `housing_alive` and `bankrupt`

**Files:**
- Modify: `lib/armchair_metropolist/domain/entities/simulation_metrics.ex`
- Test: `test/armchair_metropolist/domain/entities/simulation_metrics_test.exs`

**Interfaces:**
- Consumes: `Node.cheapest_action_cost/0` from Task 1.
- Produces: `%SimulationMetrics{housing_alive: boolean(), bankrupt: boolean()}`, both computed inside `build/2` from the nodes and `city_map.money`.

- [ ] **Step 1: Write the failing test**

Add to `simulation_metrics_test.exs`. It already aliases `CityMap`, `Node` and `SimulationMetrics`; check the top of the file and add any alias that is missing.

```elixir
describe "housing_alive" do
  test "false when every residential block sits at exactly zero health" do
    # A count-based reading would say true here — the houses are still standing.
    # This is the common death, so a reading that misses it is useless.
    city = city_with([%Node{Node.new(0, 0, :residential) | health: 0.0, status: :offline}])

    refute build(city).housing_alive
  end

  test "true when one residential block has any health at all" do
    # health 5.0 is `:offline`, and still supplies 0.25 labour. A status-based
    # reading would say false here.
    city = city_with([%Node{Node.new(0, 0, :residential) | health: 5.0, status: :offline}])

    assert build(city).housing_alive
  end

  test "false when the city has no residential blocks" do
    city = city_with([Node.new(0, 0, :power_plant)])

    refute build(city).housing_alive
  end
end

describe "bankrupt" do
  test "true just below the cheapest action" do
    # 9.0 and 10.0 rather than 0.0 and something large: a fixture at 0.0 cannot tell
    # `money < 10` apart from `money == 0`, and these two straddle the real boundary.
    assert build(%{CityMap.new(40, 30) | money: 9.0}).bankrupt
  end

  test "false at exactly the cheapest action" do
    refute build(%{CityMap.new(40, 30) | money: 10.0}).bankrupt
  end
end

# Helpers — put these at the bottom of the module, beside any existing private helpers.
defp city_with(nodes) do
  Enum.reduce(nodes, CityMap.new(40, 30), &CityMap.put_node(&2, &1))
end

defp build(city_map) do
  SimulationMetrics.build(city_map, %{})
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/armchair_metropolist/domain/entities/simulation_metrics_test.exs`
Expected: FAIL — `key :housing_alive not found in: %ArmchairMetropolist.Domain.Entities.SimulationMetrics{...}`

- [ ] **Step 3: Write minimal implementation**

In `simulation_metrics.ex`:

Extend `@type t`. `amenity_labour: float()` is currently the **last** entry and carries no
trailing comma, so it needs one — the tail becomes exactly:

```elixir
          amenity_labour: float(),
          housing_alive: boolean(),
          bankrupt: boolean()
        }
```

Extend `defstruct` the same way. `amenity_labour: 0.0` is currently the last entry, so the
tail becomes exactly:

```elixir
            amenity_labour: 0.0,
            housing_alive: false,
            bankrupt: false
```

Extend `build/3`'s returned struct. `amenity_labour: Map.fetch!(amenity, :amenity_labour)`
is currently the last field and carries no trailing comma, so the tail becomes exactly:

```elixir
      amenity_labour: Map.fetch!(amenity, :amenity_labour),
      housing_alive: housing_alive?(nodes),
      bankrupt: city_map.money < Node.cheapest_action_cost()
    }
```

`nodes` is already bound at the top of `build/3` (`nodes = CityMap.nodes(city_map)`), and
`Node` is already aliased in this module.

And add the private helper beside `count_offline_nodes/1`:

```elixir
  # `health > 0.0`, not a count and not a status. Residential is the only type that
  # consumes no labour, so it is the only source of labour supply; at exactly zero
  # health that supply is exactly 0.0 and every other type starves at the full decay
  # rate. A block at health 5 is `:offline` and still supplies 0.25 labour, so a
  # status-based reading would call a city doomed while it is still being staffed.
  defp housing_alive?(nodes) do
    Enum.any?(nodes, &(&1.type == :residential and &1.health > 0.0))
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/armchair_metropolist/domain/entities/simulation_metrics_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
mix precommit
git add lib/armchair_metropolist/domain/entities/simulation_metrics.ex test/armchair_metropolist/domain/entities/simulation_metrics_test.exs
git commit -m "feat(domain): report living housing and bankruptcy on the metrics"
```

---

### Task 3: `stalled` and `game_over?/1`

**Files:**
- Modify: `lib/armchair_metropolist/domain/services/simulation_calculator.ex`
- Modify: `lib/armchair_metropolist/domain/entities/simulation_metrics.ex`
- Test: `test/armchair_metropolist/domain/services/simulation_calculator_test.exs`
- Test: `test/armchair_metropolist/domain/entities/simulation_metrics_test.exs`

**Interfaces:**
- Consumes: `SimulationMetrics.build/3` from Task 2.
- Produces: `%SimulationMetrics{stalled: boolean()}` and `SimulationMetrics.game_over?(metrics) :: boolean()`. `build/3`'s third argument is renamed `derived` and now requires a `:stalled` key alongside the three `:amenity*` keys.
- Breaks, and therefore rewrites in Step 1: the two tests in `simulation_metrics_test.exs`
  that pass a third argument (`"carries the amenity figures it is given"` and `"raises
  rather than defaulting when the amenity map is missing a figure"`). They are the only
  `build/3` call sites in the tree outside `SimulationCalculator.metrics/1`.

- [ ] **Step 1: Write the failing test**

In `simulation_calculator_test.exs`. **The module under test is aliased as `Calc` there**
(`alias ArmchairMetropolist.Domain.Services.SimulationCalculator, as: Calc`), not as
`SimulationCalculator` — spelling it out in full would not compile:

```elixir
describe "stalled" do
  test "a fresh city is not stalled" do
    # `Enum.all?/2` over no nodes is true, and avg_health of an empty city is 0.0 —
    # so an untouched grid satisfies the naive "everything is dead" reading. This is
    # the case the non-empty clause exists for.
    refute Calc.metrics(CityMap.new(40, 30)).stalled
  end

  test "two dead houses are not stalled — they heal from an empty treasury" do
    # 15 x 2 = 30 power against the free baseline of 40, so they are fully supplied
    # and regenerate. Consumption is not health-scaled, which is what makes the
    # count the deciding factor.
    refute Calc.metrics(dead_houses(2)).stalled
  end

  test "three dead houses are stalled" do
    # 15 x 3 = 45 against 40. The cliff is 15n <= 40.
    assert Calc.metrics(dead_houses(3)).stalled
  end

  test "three starving houses above zero health are not stalled" do
    # Starving (45 power demanded against 40) but not yet at the floor, so they are
    # still losing health rather than stuck. This is what separates `health == 0.0`
    # from a status- or threshold-based reading; without it, relaxing the clause to
    # `health < 20.0` would go unnoticed.
    refute Calc.metrics(houses(3, 10.0)).stalled
  end
end

# Helpers — add beside `map_with/1` and the other module-level private helpers at the top
# of the file. `map_with/1` is not reused: these need per-node health and status set, and
# threading that through it would change a helper five other fixtures depend on.
defp houses(count, health) do
  Enum.reduce(0..(count - 1)//1, CityMap.new(40, 30), fn x, map ->
    CityMap.put_node(map, %Node{
      Node.new(x, 0, :residential)
      | health: health,
        status: Node.status_for(health)
    })
  end)
end

defp dead_houses(count), do: %{houses(count, 0.0) | money: 0.0}
```

In `simulation_metrics_test.exs`:

```elixir
describe "game_over?/1" do
  test "true only when the city is both stalled and bankrupt" do
    assert SimulationMetrics.game_over?(%SimulationMetrics{stalled: true, bankrupt: true})
  end

  test "false for a stalled city that can still afford to act" do
    # This is the state a rescue is possible from, so calling it game over would be
    # a false claim. Also what an `or` in place of the `and` would break.
    refute SimulationMetrics.game_over?(%SimulationMetrics{stalled: true, bankrupt: false})
  end

  test "false for a broke city that is still running" do
    refute SimulationMetrics.game_over?(%SimulationMetrics{stalled: false, bankrupt: true})
  end
end
```

**Two tests already in `simulation_metrics_test.exs` pass a third argument, and the new
required key breaks both.** They must be updated in this same step, not left for the
executor to discover — `Map.fetch!(derived, :stalled)` raises `KeyError` on a map that
carries only the three `:amenity*` keys.

Replace `test "carries the amenity figures it is given"` with:

```elixir
  test "carries the derived figures it is given" do
    metrics =
      SimulationMetrics.build(CityMap.new(40, 30), %{}, %{
        amenity: 1.75,
        amenity_marginal_labour: 5.0,
        amenity_labour: 15.0,
        stalled: true
      })

    assert metrics.amenity == 1.75
    assert metrics.amenity_marginal_labour == 5.0
    assert metrics.amenity_labour == 15.0

    # `true` rather than `false`: the struct default is `false`, so a build that dropped
    # this key on the floor would still satisfy a `refute`.
    assert metrics.stalled
  end
```

And replace `test "raises rather than defaulting when the amenity map is missing a
figure"` with the version below. **The map must be complete except for exactly one key.**
Left as it was — missing `amenity_labour` *and* `stalled` — the assertion would go on
passing even if every remaining `Map.fetch!` were relaxed to a defaulting `Map.get`,
because `:stalled` alone would still raise. That is the "test that cannot fail" this
rename would quietly introduce.

```elixir
  # A partial derived map is a programming error, not a request for defaults: the default
  # applies to the argument as a whole, so silently filling one missing key would let a
  # caller that computed three figures out of four ship an amenity-free labour total.
  #
  # Exactly one key is withheld, and it is named in the assertion. With two or more
  # missing, this passes for whichever one `build/3` happens to fetch first and says
  # nothing about the others.
  test "raises rather than defaulting when the derived map is missing a figure" do
    assert_raise KeyError, ~r/:amenity_labour/, fn ->
      SimulationMetrics.build(CityMap.new(40, 30), %{}, %{
        amenity: 1.75,
        amenity_marginal_labour: 5.0,
        stalled: false
      })
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/armchair_metropolist/domain/services/simulation_calculator_test.exs test/armchair_metropolist/domain/entities/simulation_metrics_test.exs`
Expected: FAIL — `key :stalled not found` and `function SimulationMetrics.game_over?/1 is undefined`

- [ ] **Step 3: Write minimal implementation**

In `simulation_metrics.ex`:

Rename the default constant and extend it — replace the `@default_amenity` block with:

```elixir
  # A city with no parks has no amenity, so the identity multiplier and zero labour from it
  # are the correct values rather than filler, and a city with no nodes is not stalled. The
  # default exists because `build/2` has a dozen call sites in tests; the one production
  # caller, `Domain.Services.SimulationCalculator.metrics/1`, always passes real figures,
  # and a test on that wiring is what stops this default reaching a player.
  @default_derived %{
    amenity: 1.0,
    amenity_marginal_labour: 0.0,
    amenity_labour: 0.0,
    stalled: false
  }
```

Add `stalled` to `@type t` and to `defstruct`. Task 2 left `bankrupt` last in both with no
trailing comma, so the tails become exactly:

```elixir
          housing_alive: boolean(),
          bankrupt: boolean(),
          stalled: boolean()
        }
```

```elixir
            housing_alive: false,
            bankrupt: false,
            stalled: false
```

Rename `build/3`'s third parameter and read the new key — change the head to
`def build(city_map, resources, derived \\ @default_derived) do`, replace every
`Map.fetch!(amenity, …)` with `Map.fetch!(derived, …)`, and add:

```elixir
      stalled: Map.fetch!(derived, :stalled),
```

to the returned struct, beside `housing_alive` and `bankrupt`.

Update `build/3`'s `@doc` so it describes `derived` rather than `amenity`: the map now
carries `:amenity`, `:amenity_marginal_labour`, `:amenity_labour` and `:stalled`, all
computed by `Domain.Services.SimulationCalculator`, which this module cannot call —
`Domain` has `deps: []` — so they arrive as an argument rather than being derived here.

Add the public function, after `build/3`:

```elixir
  @doc """
  Whether this city can never change again.

  Both halves are needed and neither implies the other. `stalled` means the clock has
  stopped, but a stalled city holding money can still be rescued — one demolition is
  enough to take three dead houses back under the free baseline. `bankrupt` means no
  command is affordable, but a running city that is merely broke still earns.

  Defined here, once, rather than composed at each call site: the template and
  `docs/PLAYING.md` both describe this state and must not be able to disagree about it.
  """
  @spec game_over?(t()) :: boolean()
  def game_over?(%__MODULE__{stalled: stalled, bankrupt: bankrupt}), do: stalled and bankrupt
```

In `simulation_calculator.ex`, rewrite `metrics/1`:

```elixir
  def metrics(city_map) do
    nodes = CityMap.nodes(city_map)
    stats = resource_stats(city_map)

    derived = %{
      amenity: labour_multiplier(nodes),
      amenity_marginal_labour: marginal_amenity_labour(nodes),
      amenity_labour: placed_amenity_labour(nodes),
      stalled: stalled?(nodes, stats)
    }

    SimulationMetrics.build(city_map, stats, derived)
  end
```

And add the private predicate, beside `worst_satisfaction/2`:

```elixir
  # The city has reached a fixpoint in health: every node is on the floor and every
  # node is still short of something, so `health_delta/1` is negative for all of them,
  # the clamp holds them at zero, and demand — which is not health-scaled — does not
  # move. The next tick is therefore identical in every node.
  #
  # Both clauses are load-bearing. Without the empty-list clause an untouched grid is
  # "stalled", because `Enum.all?/2` over nothing is true. Without the satisfaction
  # test, one or two dead houses are called stalled the tick before they heal: they
  # draw 30 power against the free baseline of 40, so they are fully supplied at zero
  # health and regenerate. The cliff is `15n <= 40`.
  #
  # Written per-node rather than against `avg_health`: health is clamped non-negative,
  # so "every node at 0.0" and "the average is 0.0 over a non-empty set" say the same
  # thing, and this form has no float sum in it to reason about.
  defp stalled?([], _stats), do: false

  defp stalled?(nodes, stats) do
    Enum.all?(nodes, fn node ->
      node.health == @min_health and worst_satisfaction(node, stats) < 1.0
    end)
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/armchair_metropolist/domain`
Expected: PASS — including the two pre-existing `build/3` tests rewritten in Step 1. Those
two are the only callers in the tree that pass a third argument; every other call site uses
`build/2` and picks up `@default_derived`, so nothing else moves.

- [ ] **Step 5: Commit**

```bash
mix precommit
git add lib/armchair_metropolist/domain test/armchair_metropolist/domain
git commit -m "feat(domain): detect a stalled city and compose the game-over state"
```

---

### Task 4: The engine freezes a stalled city

**Files:**
- Modify: `lib/armchair_metropolist/infrastructure/simulation/city_engine.ex` (`handle_info({:tick, …})`, ~line 300, and the moduledoc)
- Test: `test/armchair_metropolist/infrastructure/simulation/city_engine_test.exs`

**Interfaces:**
- Consumes: `metrics.stalled` from Task 3.
- Produces: no new public function. Behaviour only: a stalled engine ignores `{:tick, n}`.
  Also produces the test helper `dead_city(house_count, health)` in `city_engine_test.exs`,
  which Task 8 reuses — leave it at module level beside the file's other private helpers.

- [ ] **Step 1: Write the failing test**

Add a new `describe` block to `city_engine_test.exs`. Its `setup` already gives `city_id`,
and the file already has a `broadcast_tick/1` helper (bottom of the module) — use it rather
than spelling out `Phoenix.PubSub.broadcast/3`, which is what every other tick test here
does.

```elixir
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
    StubSnapshotRepository.set_initial({:ok, {3, dead_city(2, 0.0)}})
    start_supervised!({CityEngine, city_id: city_id})

    {:ok, %{metrics: metrics}} = CityEngine.snapshot(city_id)
    refute metrics.stalled

    broadcast_tick(1)

    {:ok, %{city_map: city_map}} = CityEngine.snapshot(city_id)
    assert city_map.tick == 4
  end

  test "a placement unfreezes a stalled city that can still afford one", %{city_id: city_id} do
    # The freeze is not a lockout. Three dead houses have no money demand at all —
    # residential consumes none — so their treasury never drained, and 105 covers the
    # 80 a power plant costs.
    #
    # What unfreezes the city is the *new block's own health*, not a rescue of the
    # houses: `stalled?` is `Enum.all?`, and a node placed at 100.0 fails the
    # `health == @min_health` half immediately. Measured, the placement does not in
    # fact rescue the houses — the plant's own draw takes water from 36/40 to 56/40
    # and labour supply is 0.0 with no living housing, so ten ticks later the three
    # houses are still at 0.0 and the plant itself has decayed to 40.0. That is a
    # worse deficit than the 45/40 power shortfall it replaced. The clock restarting
    # is the whole claim here; do not restate it as a recovery.
    StubSnapshotRepository.set_initial({:ok, {3, %{dead_city(3, 0.0) | money: 105.0}}})
    start_supervised!({CityEngine, city_id: city_id})

    assert {:ok, %{metrics: %{stalled: true}}} = CityEngine.snapshot(city_id)

    assert {:ok, _node} = CityEngine.place(city_id, 10, 10, :power_plant)

    assert {:ok, %{metrics: %{stalled: false}}} = CityEngine.snapshot(city_id)
  end

  test "demolishing back inside the free baseline unfreezes without building", %{
    city_id: city_id
  } do
    # The other unfreeze, and the one the game-over copy leans on: three dead houses
    # draw 45 power against the free baseline of 40, two draw 30, so tearing one down
    # for 10 makes the survivors fully supplied at zero health and they regenerate.
    #
    # Seeded at exactly 10.0 — the demolition fee, and the `bankrupt` boundary. At 9
    # the command is refused and this test would assert nothing about the freeze.
    StubSnapshotRepository.set_initial({:ok, {3, %{dead_city(3, 0.0) | money: 10.0}}})
    start_supervised!({CityEngine, city_id: city_id})

    assert {:ok, %{metrics: %{stalled: true}}} = CityEngine.snapshot(city_id)

    assert {:ok, _id} = CityEngine.demolish(city_id, 2, 0)

    assert {:ok, %{metrics: %{stalled: false}}} = CityEngine.snapshot(city_id)
  end
end

# Helper — add beside the file's other private helpers, at the bottom of the module.
defp dead_city(house_count, health) do
  city =
    Enum.reduce(0..(house_count - 1)//1, CityMap.new(40, 30), fn x, map ->
      CityMap.put_node(map, %Node{
        Node.new(x, 0, :residential)
        | health: health,
          status: Node.status_for(health)
      })
    end)

  %{city | tick: 3, money: 0.0}
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/armchair_metropolist/infrastructure/simulation/city_engine_test.exs`
Expected: FAIL — and only one of the four, "ignores the clock once the city has stalled",
on `assert city_map.tick == 3`, because the tick advanced to 4. That is the whole of what
this task's clause changes. "a running city still advances" is the other direction of the
same assertion and is green either way; the two unfreeze tests are green before the change
too, because the mutation they exist for is a *lockout* added to `handle_call` rather than
anything in the freeze clause. They are worth having for that reason and for nothing else
— do not read their passing here as a missing implementation.

- [ ] **Step 3: Write minimal implementation**

In `city_engine.ex`, the tick handler today reads:

```elixir
  # The clock's pulse number is deliberately discarded: city_map.tick is the
  # authority.
  @impl true
  def handle_info({:tick, _clock_pulse}, state) do
```

Replace those four lines with the block below, leaving the existing body attached to the
second head. `@impl true` moves onto the new first clause and must not be repeated on the
second — Elixir warns on `@impl` for a later clause of the same function, and
`--warnings-as-errors` turns that into a failed build.

```elixir
  # A stalled city has reached a fixpoint in health, so advancing it would recompute an
  # identical result — but this is not only an optimisation. Money demand is not
  # health-scaled either, so a stalled city with a water plant, transit hub or park goes
  # on draining its treasury, and that treasury is exactly what a rescue is paid for.
  # Freezing preserves it, which makes "stalled but solvent" a stable state a player can
  # act on rather than a countdown.
  #
  # Not a lockout: `handle_call({:place, …})` does not tick, so a player with money left
  # can still build, the recomputed metrics clear this flag, and the clock resumes on the
  # next pulse.
  #
  # Nothing is persisted for this. `handle_continue(:hydrate, …)` recomputes metrics, so a
  # stalled city loads stalled and stays frozen — the same reasoning that keeps `critical?`
  # derived rather than stored.
  @impl true
  def handle_info({:tick, _clock_pulse}, %{metrics: %{stalled: true}} = state) do
    {:noreply, state}
  end

  # The clock's pulse number is deliberately discarded: city_map.tick is the
  # authority.
  def handle_info({:tick, _clock_pulse}, state) do
```

`state.metrics` is `nil` between `init/1` and `handle_continue(:hydrate, …)`, and the map
pattern above would not match it — but `handle_continue/2` runs before any mailbox message,
so no tick can reach either clause while it is nil.

Also add a section to the moduledoc, after the "Two tick counters, one authority" section:

```elixir
  ## Freezing a collapsed city

  When `metrics.stalled` is true the engine ignores `{:tick, n}` entirely: no
  `AdvanceCityTick`, no broadcast, no checkpoint, no deficit notification. See the
  clause itself for why this preserves the treasury rather than merely saving work.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/armchair_metropolist/infrastructure/simulation/city_engine_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
mix precommit
git add lib/armchair_metropolist/infrastructure/simulation/city_engine.ex test/armchair_metropolist/infrastructure/simulation/city_engine_test.exs
git commit -m "feat(engine): stop ticking a city that has stalled"
```

---

### Task 5: `CityMap.reset/1`

**Files:**
- Modify: `lib/armchair_metropolist/domain/entities/city_map.ex` (after `new/2`)
- Test: `test/armchair_metropolist/domain/entities/city_map_test.exs`

**Interfaces:**
- Consumes: nothing.
- Produces: `CityMap.reset(map) :: CityMap.t()` — same dimensions, tick 0, no nodes, money back to `opening_grant/0`.

- [ ] **Step 1: Write the failing test**

```elixir
describe "reset/1" do
  test "keeps the grid dimensions and discards everything else" do
    city =
      CityMap.new(12, 7)
      |> CityMap.put_node(Node.new(1, 1, :power_plant))
      |> CityMap.debit(100.0)

    city = %{city | tick: 412}

    reset = CityMap.reset(city)

    # Each property named separately: a reset that forgets one of these is a real bug
    # and a single `==` against a literal struct would not say which.
    assert reset.width == 12
    assert reset.height == 7
    assert reset.tick == 0
    assert reset.nodes == %{}
    assert reset.money == CityMap.opening_grant()
  end

  test "a reset city is indistinguishable from a new one of the same size" do
    city = CityMap.put_node(CityMap.new(40, 30), Node.new(3, 3, :commercial))

    assert CityMap.reset(city) == CityMap.new(40, 30)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/armchair_metropolist/domain/entities/city_map_test.exs`
Expected: FAIL — `function ArmchairMetropolist.Domain.Entities.CityMap.reset/1 is undefined or private`

- [ ] **Step 3: Write minimal implementation**

In `city_map.ex`, immediately after `new/2`:

```elixir
  @doc """
  Discard this city and start a new one on the same grid.

  Tick 0, no nodes, and the treasury back to `opening_grant/0` — delegating to `new/2`
  rather than resetting fields by hand, so there is exactly one definition of what a new
  city is and this cannot drift from it.

  The grant has to come back. A collapsed city's treasury has drained to zero and the
  cheapest block costs 15, so a wipe that cleared the grid and left the balance alone
  would trade one dead end for another: an empty grid earns nothing, forever.
  """
  @spec reset(t()) :: t()
  def reset(map), do: new(map.width, map.height)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/armchair_metropolist/domain/entities/city_map_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
mix precommit
git add lib/armchair_metropolist/domain/entities/city_map.ex test/armchair_metropolist/domain/entities/city_map_test.exs
git commit -m "feat(domain): reset a city map to a fresh grid"
```

---

### Task 6: `SnapshotRepository.delete/1`

**Files:**
- Modify: `lib/armchair_metropolist/domain/ports/snapshot_repository.ex`
- Modify: `lib/armchair_metropolist/infrastructure/persistence/snapshot_store.ex`
- Modify: `lib/armchair_metropolist/infrastructure/persistence/file_snapshot_store.ex`
- Modify: `test/support/snapshot_repository_contract.ex`
- Modify: `test/support/stub_snapshot_repository.ex`
- Modify: `test/support/slow_snapshot_repository.ex`
- Test: exercised through `test/armchair_metropolist/infrastructure/persistence/snapshot_store_test.exs` and `file_snapshot_store_test.exs`, both of which already `use ArmchairMetropolist.SnapshotRepositoryContract`.

**Interfaces:**
- Consumes: nothing.
- Produces: `@callback delete(String.t()) :: :ok | {:error, term()}` on the port, implemented by both adapters and all test doubles. `StubSnapshotRepository.calls/0 :: [{:save, String.t(), non_neg_integer()} | {:delete, String.t()}]` (newest first) and `StubSnapshotRepository.fail_deletes(term())`.

- [ ] **Step 1: Write the failing test**

Add to the `quote do` block in `test/support/snapshot_repository_contract.ex`, after the
last existing `test`:

```elixir
      test "delete/1 removes the stored city" do
        assert :ok = @adapter.save(@city_id, 7, sample_city())
        assert :ok = @adapter.delete(@city_id)
        assert {:error, :not_found} = @adapter.load(@city_id)
      end

      test "delete/1 is :ok when nothing is stored" do
        # A reset of a city that has never been checkpointed is ordinary, not an error.
        assert :ok = @adapter.delete(@city_id)
      end

      test "after delete/1 a lower tick can be saved again" do
        # The whole reason this callback exists. `save/3` is monotonic in tick, so a
        # city reset to tick 0 is unsaveable until it climbs back past what is stored —
        # during which a restart would restore the city the player just wiped.
        assert :ok = @adapter.save(@city_id, 9, CityMap.new(19, 19))
        assert {:stale, 9} = @adapter.save(@city_id, 1, CityMap.new(11, 11))

        assert :ok = @adapter.delete(@city_id)

        assert :ok = @adapter.save(@city_id, 1, CityMap.new(11, 11))
        assert {:ok, {1, loaded}} = @adapter.load(@city_id)
        assert loaded.width == 11
      end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/armchair_metropolist/infrastructure/persistence/`
Expected: FAIL — `function ArmchairMetropolist.Infrastructure.Persistence.SnapshotStore.delete/1 is undefined`

- [ ] **Step 3: Write minimal implementation**

In `snapshot_repository.ex`, after the `save/3` callback:

```elixir
  @doc """
  Delete the city stored under `city_id`.

  Returns `:ok` when nothing was stored — a reset of a city that has never been
  checkpointed is ordinary, not a failure.

  Exists because `save/3` is monotonic in tick and must stay that way. A reset city
  starts again at tick 0, which `save/3` correctly refuses as stale until the new city
  outlives the old one; deleting the stored row is how a wipe becomes durable without
  putting a hole in that guarantee. See `UseCases.ResetCity` and
  `Infrastructure.Simulation.CityEngine.handle_call(:reset, …)`.
  """
  @callback delete(String.t()) :: :ok | {:error, term()}
```

In `snapshot_store.ex`, after `save/3`:

```elixir
  @impl true
  def delete(city_id) do
    Repo.delete_all(from(s in CitySnapshot, where: s.city_id == ^city_id))

    :ok
  rescue
    # Same never-raise policy as `save/3` above, and for the same reason: this runs
    # inside a `GenServer.call` on the engine, and a raise there takes the city with it.
    exception -> {:error, exception}
  catch
    kind, value -> {:error, {kind, value}}
  end
```

In `file_snapshot_store.ex`, after `save/3`:

```elixir
  # The city id is accepted and ignored, exactly as `load/1` ignores it: this adapter
  # keeps one pair of files for one city.
  #
  # The temp file is removed too. It is normally absent — `write_snapshot/1` renames it
  # into place — but a crash mid-write can leave one, and a wipe should not leave a
  # fragment of the discarded city on disk.
  #
  # sobelow_skip ["Traversal.FileModule"]
  # Required, not decorative: `:rm` is on `Traversal.FileModule`'s function list and the
  # path here is a variable, and `.sobelow-conf` sets `exit: "low"`, so an unannotated
  # finding fails `mix check`. Sobelow rewrites this comment to `@sobelow_skip [...]` and
  # pairs it with the next `def` it collects — `@doc` and `@impl` go to a different bucket
  # and do not break the pairing, but another `def` in between would. Same justification
  # as the other skips here: the paths come from `:snapshot_dir` config, never from a
  # request.
  @impl true
  def delete(_city_id) do
    Enum.reduce([primary_path(), backup_path(), tmp_path()], :ok, fn path, outcome ->
      case File.rm(path) do
        :ok -> outcome
        {:error, :enoent} -> outcome
        {:error, reason} -> {:error, reason}
      end
    end)
  end
```

In `test/support/stub_snapshot_repository.ex`:

- Change `start_link/1`'s initial state to
  `%{initial: {:error, :not_found}, saves: [], calls: []}`.
- In `save/3`'s `nil` branch, also record the call — replace that branch's body with
  `{:ok, %{state | saves: [{city_id, tick, city_map} | state.saves], calls: [{:save, city_id, tick} | state.calls]}}`.
- Add:

```elixir
  @doc """
  Every call this adapter received, newest first.

  `saves/0` answers "what was written"; this answers "in what order, against what else".
  The engine's reset has to delete before it saves — the ordering *is* the error
  handling, since a failed delete then shows up as the save being refused as stale — so
  that ordering is behaviour worth asserting rather than an implementation detail.
  """
  def calls, do: Agent.get(__MODULE__, & &1.calls)

  @doc "Make delete/1 fail, to prove the engine still resets in memory."
  def fail_deletes(reason) do
    Agent.update(__MODULE__, &Map.put(&1, :delete_result, {:error, reason}))
  end

  @impl true
  def delete(city_id) do
    Agent.get_and_update(__MODULE__, fn state ->
      calls = [{:delete, city_id} | state.calls]

      case Map.get(state, :delete_result, :ok) do
        # Clears `saves` as well as answering, so a subsequent `saves/0` reports what
        # the engine wrote *after* the wipe rather than the discarded city's history.
        # Note this does not make `load/1` report nothing: under `echo_saves/0` an empty
        # `saves` falls back to whatever `set_initial/1` seeded, which is the old city.
        # No test relies on that path today; a future one that does needs a real
        # tombstone here rather than an empty list.
        :ok -> {:ok, %{state | saves: [], calls: calls}}
        error -> {error, %{state | calls: calls}}
      end
    end)
  end
```

In `test/support/slow_snapshot_repository.ex`, after `save/3`:

```elixir
  @impl true
  def delete(city_id), do: StubSnapshotRepository.delete(city_id)
```

Also add `delete/1` to `ArmchairMetropolist.FailingSnapshotRepository` at the top of
`city_engine_test.exs`, so it still satisfies the behaviour:

```elixir
  @impl true
  def delete(_city_id), do: {:error, :disk_full}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/armchair_metropolist/infrastructure/persistence/ test/armchair_metropolist/infrastructure/simulation/`
Expected: PASS. Both adapter test files inherit the three new contract cases, so this is
six new passing tests plus no regressions.

Then run: `mix sobelow`
Expected: no findings, exit 0. This is the only task that adds a call Sobelow flags
(`File.rm`). The `.githooks/pre-commit` hook would catch it at `git commit` anyway, but
running it here separates "my skip annotation is misplaced" from "my commit is broken".
If it reports `Traversal.FileModule` against `delete/1`, the skip comment is not where
Sobelow expects it; see the note beside it.

- [ ] **Step 5: Commit**

```bash
mix precommit
git add lib/armchair_metropolist/domain/ports/snapshot_repository.ex lib/armchair_metropolist/infrastructure/persistence test/support test/armchair_metropolist/infrastructure/simulation/city_engine_test.exs
git commit -m "feat(persistence): let a city be deleted, so a reset can persist at tick 0"
```

---

### Task 7: `UseCases.ResetCity`

**Files:**
- Create: `lib/armchair_metropolist/use_cases/reset_city.ex`
- Test: `test/armchair_metropolist/use_cases/reset_city_test.exs`

**Interfaces:**
- Consumes: `CityMap.reset/1` (Task 5), `SimulationCalculator.metrics/1` (Task 3).
- Produces: `ResetCity.execute(city_map) :: {:ok, %{city_map: CityMap.t(), metrics: SimulationMetrics.t()}}`.

- [ ] **Step 1: Write the failing test**

Create `test/armchair_metropolist/use_cases/reset_city_test.exs`:

```elixir
defmodule ArmchairMetropolist.UseCases.ResetCityTest do
  use ExUnit.Case, async: true

  alias ArmchairMetropolist.Domain.Entities.CityMap
  alias ArmchairMetropolist.Domain.Entities.Node
  alias ArmchairMetropolist.UseCases.ResetCity

  test "returns a fresh city and the metrics of that city, not of the old one" do
    city =
      CityMap.new(40, 30)
      |> CityMap.put_node(%Node{Node.new(0, 0, :residential) | health: 0.0, status: :offline})
      |> CityMap.debit(150.0)

    city = %{city | tick: 99}

    assert {:ok, %{city_map: reset, metrics: metrics}} = ResetCity.execute(city)

    assert reset == CityMap.new(40, 30)

    # Computed from the *new* map, the same way AdvanceCityTick computes from the
    # post-tick map. Metrics of the old city here would leave the view rendering a
    # collapse banner over an empty grid.
    assert metrics.tick == 0
    assert metrics.node_count == 0
    assert metrics.money == CityMap.opening_grant()
    refute metrics.stalled
    refute metrics.bankrupt
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/armchair_metropolist/use_cases/reset_city_test.exs`
Expected: FAIL — `module ArmchairMetropolist.UseCases.ResetCity is not available`

- [ ] **Step 3: Write minimal implementation**

Create `lib/armchair_metropolist/use_cases/reset_city.ex`:

```elixir
defmodule ArmchairMetropolist.UseCases.ResetCity do
  @moduledoc "Use case: discard a city and start a new one on the same grid."

  alias ArmchairMetropolist.Domain.Entities.CityMap
  alias ArmchairMetropolist.Domain.Entities.SimulationMetrics
  alias ArmchairMetropolist.Domain.Services.SimulationCalculator

  @doc """
  Reset `city_map` and return it with its metrics.

  Metrics describe the *new* map, mirroring `AdvanceCityTick.execute/1`, which computes
  from the post-tick map for the same reason.

  This use case exists so `Infrastructure.Simulation.CityEngine` can get those metrics at
  all: the boundary graph bars `Infrastructure` from `Domain.Services`, so the engine
  cannot call `SimulationCalculator` itself.

  Persisting the reset is deliberately *not* here. It needs the city id and the
  repository, neither of which belongs in a pure function; see the engine's
  `handle_call(:reset, …)`.
  """
  @spec execute(CityMap.t()) :: {:ok, %{city_map: CityMap.t(), metrics: SimulationMetrics.t()}}
  def execute(city_map) do
    next = CityMap.reset(city_map)

    {:ok, %{city_map: next, metrics: SimulationCalculator.metrics(next)}}
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/armchair_metropolist/use_cases/reset_city_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
mix precommit
git add lib/armchair_metropolist/use_cases/reset_city.ex test/armchair_metropolist/use_cases/reset_city_test.exs
git commit -m "feat(use-cases): add the ResetCity use case"
```

---

### Task 8: `CityEngine.reset/1`

**Files:**
- Modify: `lib/armchair_metropolist/infrastructure/simulation/city_engine.ex`
- Test: `test/armchair_metropolist/infrastructure/simulation/city_engine_test.exs`

**Interfaces:**
- Consumes: `ResetCity.execute/1` (Task 7), `SnapshotRepository.delete/1` and
  `StubSnapshotRepository.calls/0` / `fail_deletes/1` (Task 6), and the `dead_city/2` test
  helper Task 4 added to `city_engine_test.exs`. `broadcast_tick/1` and
  `import ExUnit.CaptureLog` are already in that file.
- Produces: `CityEngine.reset(city_id) :: :ok`. Broadcasts `:city_reset` then `{:city_metrics, metrics}` on `topic(city_id)`.

- [ ] **Step 1: Write the failing test**

```elixir
describe "reset/1" do
  test "clears the city, restores the grant, and returns to tick 0", %{city_id: city_id} do
    StubSnapshotRepository.set_initial({:ok, {3, dead_city(3, 0.0)}})
    start_supervised!({CityEngine, city_id: city_id})

    assert :ok = CityEngine.reset(city_id)

    {:ok, %{city_map: city_map, metrics: metrics}} = CityEngine.snapshot(city_id)
    assert city_map.nodes == %{}
    assert city_map.tick == 0
    assert city_map.money == CityMap.opening_grant()
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
    assert [{:save, ^city_id, 0}, {:delete, ^city_id} | _] = StubSnapshotRepository.calls()
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

    assert first == :city_reset
    assert {:city_metrics, %{node_count: 0, tick: 0}} = second
  end

  test "a reset city ticks again", %{city_id: city_id} do
    # The freeze from Task 4 must not survive the reset.
    StubSnapshotRepository.set_initial({:ok, {3, dead_city(3, 0.0)}})
    start_supervised!({CityEngine, city_id: city_id})

    assert :ok = CityEngine.reset(city_id)

    broadcast_tick(1)

    {:ok, %{city_map: city_map}} = CityEngine.snapshot(city_id)
    assert city_map.tick == 1
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/armchair_metropolist/infrastructure/simulation/city_engine_test.exs`
Expected: FAIL — `function ArmchairMetropolist.Infrastructure.Simulation.CityEngine.reset/1 is undefined`

- [ ] **Step 3: Write minimal implementation**

Add the alias near the other `alias ArmchairMetropolist.UseCases.…` lines:

```elixir
  alias ArmchairMetropolist.UseCases.ResetCity
```

Add the public function, after `demolish/3`:

```elixir
  @doc """
  Discard this city and start a new one on the same grid.

  Deletes the stored snapshot, so the tick-0 city that replaces it is durable
  immediately rather than unsaveable until it outlives the city it replaced.
  """
  @spec reset(String.t()) :: :ok
  def reset(city_id), do: call(city_id, :reset)
```

Add the handler, after `handle_call({:demolish, …}, …)`:

```elixir
  def handle_call(:reset, _from, state) do
    {:ok, %{city_map: city_map, metrics: metrics}} = ResetCity.execute(state.city_map)

    # Delete first, then save — and the order is the error handling. `save/3` is
    # monotonic in tick, so with the old row still present this save at tick 0 is
    # refused as `{:stale, _}` and lands in `save/2`'s existing warning path, which
    # already means "this engine's city is older than what is stored". A failed delete
    # therefore reports itself through a path that exists, with no new branch and no new
    # error policy. Reversed, the save would be refused *before* the delete and the new
    # city would never reach storage at all.
    #
    # Saving here rather than waiting for the next checkpoint: a player who wipes and
    # immediately closes the tab would otherwise get the collapsed city back.
    delete(state.city_id)
    save(state.city_id, city_map)

    broadcast(state.city_id, :city_reset)
    broadcast(state.city_id, {:city_metrics, metrics})

    # Re-armed from the new city rather than left as it was, so the next deficit is a
    # fresh edge. An empty city has no deficit, so this is `false` in practice; deriving
    # it keeps that a consequence of the city rather than a second thing to remember.
    {:reply, :ok,
     %{
       state
       | city_map: city_map,
         metrics: metrics,
         critical?: critical_resources(metrics) != []
     }}
  end
```

And the private helper, beside `save/2`:

```elixir
  # Never raises, and never returns anything but `:ok` — same policy as `save/2`, and for
  # the same reason: this runs inside a `handle_call`, and a raise here would take the
  # city down and roll it back to the last checkpoint. The consequence of a swallowed
  # failure is bounded and visible: the save that follows is refused as stale and logs.
  defp delete(city_id) do
    case snapshot_repository().delete(city_id) do
      :ok -> :ok
      {:error, reason} -> log_failed_delete(city_id, reason)
    end
  rescue
    exception -> log_failed_delete(city_id, exception)
  catch
    kind, value -> log_failed_delete(city_id, {kind, value})
  end

  defp log_failed_delete(city_id, reason) do
    Logger.error("failed to delete city snapshot for #{city_id}: #{inspect(reason)}")

    :ok
  end
```

Add to the moduledoc's "Broadcasts" section, after the `{:city_node_placed, node}` sentence:

```
`:city_reset` on a successful `reset/1`, followed by `{:city_metrics, metrics}`.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/armchair_metropolist/infrastructure/simulation/city_engine_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
mix precommit
git add lib/armchair_metropolist/infrastructure/simulation/city_engine.ex test/armchair_metropolist/infrastructure/simulation/city_engine_test.exs
git commit -m "feat(engine): reset a city, deleting its snapshot first"
```

---

### Task 9: The layout gains an actions slot and a grid wordmark

**Files:**
- Modify: `lib/armchair_metropolist_web/components/layouts.ex` (`app/1`, lines 28–57)
- Test: `test/armchair_metropolist_web/live/simulator_live_test.exs`

**Interfaces:**
- Consumes: nothing.
- Produces: `<Layouts.app flash={…}><:actions>…</:actions>…</Layouts.app>`. The slot renders in the header's right-hand group, before `<.theme_toggle />`.

- [ ] **Step 1: Write the failing test**

Add to `simulator_live_test.exs`:

```elixir
describe "the page header" do
  test "lays its action group out as a row", %{conn: conn} do
    # daisyUI's `.flex-none` is `flex: none` — an *item* property, not `display: flex`.
    # With the original markup a button added to that group stacks above the theme
    # toggle instead of beside it. No content assertion can see that: the button is
    # present, labelled and clickable either way. Only this class can.
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ ~s(class="flex flex-none items-center gap-2")
  end

  test "gives the subtitle its own full-width row, right-aligned", %{conn: conn} do
    # `text-align` aligns to the column box, not to the text in it. With a `1fr`
    # column that box is wider than the wrapped title, which pushed the subtitle 64px
    # past it; `min-content` makes box and ink coincide. Also invisible to content
    # assertions — every rendered character is identical either way.
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "grid-cols-[auto_min-content]"
    assert html =~ ~s(class="col-span-2 text-right text-[11px] opacity-60")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/armchair_metropolist_web/live/simulator_live_test.exs`
Expected: FAIL — the two new tests in the "the page header" describe block both fail,
because neither class appears in the rendered HTML. Every other test in the file passes.

- [ ] **Step 3: Write minimal implementation**

In `layouts.ex`, replace the `attr`/`slot` declarations and the `<header>` block of `app/1`:

```elixir
  attr :flash, :map, required: true, doc: "the map of flash messages"

  slot :actions,
    doc: "page controls for the header, rendered beside the theme toggle"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="navbar border-b border-base-200 px-4 sm:px-6 lg:px-8">
      <div class="flex-1">
        <%!-- A two-column grid, not a flex row with a nested column, so the subtitle can
              span the full brand width and share a right edge with the title.

              `min-content` on the second column is load-bearing and `1fr` is the trap:
              `text-right` aligns to the *column box*, and a `1fr` column stretches to fill
              the brand — measured 146px wide at a 375px viewport while the wrapped title
              inked only 82px of it, so right-aligning pushed the subtitle 64px past the
              text it was supposed to line up with. `min-content` sizes the column to the
              longest word, so box edge and ink edge coincide and the alignment is exact at
              both 375 and 1932. It also narrows the brand from 200px to 146px, which hands
              width back to the header rather than spending it.

              The title stays in column 2 beside the logo and wraps to two lines there.
              That is wanted, not tolerated. --%>
        <a
          href="/"
          class="grid w-fit grid-cols-[auto_min-content] items-center gap-x-3 gap-y-0.5"
          aria-label="Armchair Metropolist"
        >
          <.city_mark />
          <span class="text-base font-semibold tracking-tight leading-tight">
            Armchair Metropolist
          </span>
          <span class="col-span-2 text-right text-[11px] opacity-60">
            city infrastructure simulator
          </span>
        </a>
      </div>
      <%!-- `flex` is mandatory here and is not what `flex-none` provides: daisyUI's
            `.flex-none` is `flex: none`, describing how this div behaves as a *child* of
            the navbar, and says nothing about its own children. Without `flex` a second
            control stacks above the theme toggle and grows the header from 64px to 77px at
            every viewport width. --%>
      <div class="flex flex-none items-center gap-2">
        {render_slot(@actions)}
        <.theme_toggle />
      </div>
    </header>

    <main class="px-4 py-8 sm:px-6 lg:px-8">
      <div class="mx-auto w-fit max-w-full space-y-4">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end
```

Also update the `@doc`'s example to show the slot:

```elixir
      <Layouts.app flash={@flash}>
        <:actions><button>Reset</button></:actions>
        <h1>Content</h1>
      </Layouts.app>
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/armchair_metropolist_web/`
Expected: PASS. The existing `assert html =~ "Armchair Metropolist"` in "renders the grid
and the legend" must still pass — the wordmark text is unchanged, only its wrapper.

- [ ] **Step 5: Commit**

```bash
mix precommit
git add lib/armchair_metropolist_web/components/layouts.ex test/armchair_metropolist_web/live/simulator_live_test.exs
git commit -m "feat(web): give the header an actions slot and a grid wordmark"
```

---

### Task 10: The Reset button and the collapse banner

**Files:**
- Modify: `lib/armchair_metropolist_web/live/simulator_live.ex`
- Test: `test/armchair_metropolist_web/live/simulator_live_test.exs`

**Interfaces:**
- Consumes: `SimulationMetrics.game_over?/1` (Task 3), `metrics.stalled` / `.housing_alive` / `.bankrupt` (Tasks 2–3), `CityEngine.reset/1` (Task 8), `Layouts.app`'s `:actions` slot (Task 9), `Node.cheapest_construction_cost/0` and `Node.demolition_cost/0` (Task 1).
- Produces: no new module API. DOM ids `reset-city` and `collapse-banner`.

- [ ] **Step 1: Write the failing test**

First extend the test file's snapshot seeding. Add these clauses **above** the existing
`defp initial_snapshot(_context)` catch-all:

```elixir
  # `@tag :stalled_city` seeds a city that is stalled *and* bankrupt: three dead
  # residential blocks (15 x 3 = 45 power against the free baseline of 40, so they
  # starve at zero health and stay there) and an empty treasury.
  defp initial_snapshot(%{stalled_city: true}), do: {:ok, {0, stalled_city(0.0)}}

  # The same city with money in the bank — stalled, but a rescue is still affordable.
  defp initial_snapshot(%{stalled_solvent_city: true}), do: {:ok, {0, stalled_city(105.0)}}

  defp stalled_city(money) do
    city =
      Enum.reduce(0..2, CityMap.new(40, 30), fn x, map ->
        CityMap.put_node(map, %Node{
          Node.new(x, 0, :residential)
          | health: 0.0,
            status: :offline
        })
      end)

    %{city | money: money}
  end
```

Then add the tests:

```elixir
describe "the reset control" do
  test "is absent while the city has living housing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    # `select_type` first, and it is not optional. `@selected_type` defaults to
    # `List.first(Node.types())`, and `Node.types/0` is `Map.keys/1` over the production
    # table — arbitrary order, so the default is not reliably `residential`. Placing
    # whatever happens to be first would leave `housing_alive` false and this test would
    # assert the opposite of what it claims.
    render_click(view, "select_type", %{"type" => "residential"})
    render_click(view, "place", %{"x" => "1", "y" => "1"})

    refute has_element?(view, "#reset-city")
  end

  test "is absent on a fresh, empty city", %{conn: conn} do
    # No housing alive, but nothing placed and the grant intact — a reset here is a
    # no-op, so offering one is noise.
    {:ok, view, _html} = live(conn, ~p"/")

    refute has_element?(view, "#reset-city")
  end

  @tag :stalled_city
  test "appears once no housing is alive", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#reset-city")
  end

  @tag treasury: 9.0
  test "appears on an empty grid that cannot afford to act", %{conn: conn} do
    # The dead end the `node_count > 0` disjunct alone creates: demolish your way down
    # to an empty grid holding 9, and nothing costs 10 or less while an empty grid
    # earns nothing, forever.
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#reset-city")
  end

  @tag :stalled_city
  test "clears the grid and starts a new city", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert render(view) =~ ~s{id="0:0"}

    render_click(view, "wipe")

    html = render(view)
    refute html =~ ~s{id="0:0"}
    assert html =~ "Treasury: #{trunc(CityMap.opening_grant())}"
    refute has_element?(view, "#reset-city")
  end

  @tag :stalled_city
  test "another viewer's reset clears this one's grid too", %{conn: conn} do
    # The broadcast path, which the click path above cannot reach: `handle_event("wipe",
    # …)` clears this view's own stream, so deleting `handle_info(:city_reset, …)`
    # entirely leaves that test green while every *other* open tab keeps rendering the
    # city it just watched being wiped. Broadcast directly rather than opening a second
    # view, matching the removal test above.
    {:ok, view, _html} = live(conn, ~p"/")
    assert render(view) =~ ~s{id="0:0"}

    Phoenix.PubSub.broadcast(ArmchairMetropolist.PubSub, @topic, :city_reset)

    refute render(view) =~ ~s{id="0:0"}
  end

  @tag :stalled_city
  test "is sized and coloured for the contrast and target-size floors", %{conn: conn} do
    # Every one of these four classes is a measurement, and every one is invisible to a
    # content assertion — the button is present, labelled `Reset` and clickable without
    # any of them. `min-h-6` is 24px against bare `btn-xs`'s 21px, which fails WCAG 2.2's
    # 24x24 target size; `text-white` is 4.60:1 on `--color-error` against
    # `--color-error-content`'s measured 4.08:1, under the 4.5 floor for small text.
    # Asserted as one exact string so a reordering or a dropped class both go red, and
    # scoped to the button's own id so it cannot pass against some other element.
    {:ok, view, _html} = live(conn, ~p"/")

    assert view |> element("#reset-city") |> render() =~
             ~s(class="btn btn-xs btn-error text-white min-h-6")
  end
end

describe "the collapse banner" do
  @tag :stalled_city
  test "says the city is dead when nothing can restart it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#collapse-banner")
    assert render(view) =~ "Game over — this city is dead."
  end

  @tag :stalled_solvent_city
  test "says the city is stalled while a rescue is still affordable", %{conn: conn} do
    # Both banners share their second sentence, so asserting on the shared prose would
    # pass against the wrong state. The headline is the only text that separates them,
    # which is why both directions are asserted here.
    {:ok, view, _html} = live(conn, ~p"/")

    html = render(view)
    assert html =~ "City stalled — nothing is changing on its own."
    refute html =~ "this city is dead"
  end

  test "is absent while the city is running", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    refute has_element?(view, "#collapse-banner")
  end

  @tag :stalled_city
  test "is as wide as the grid", %{conn: conn} do
    # Scoped to the banner's own id. A bare `html =~ "width: 960px"` would pass with no
    # banner rendered at all, because the grid container carries that same width — the
    # assertion would be incapable of failing.
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, ~s{#collapse-banner[style*="width: #{40 * 24}px"]})
  end

  @tag :stalled_city
  test "does not render a second reset control", %{conn: conn} do
    # The banner names the header's button rather than repeating it. A later edit that
    # helpfully adds one back would ship duplicate DOM ids and a second untested event
    # path, and nothing else in the suite would notice.
    {:ok, _view, html} = live(conn, ~p"/")

    assert length(String.split(html, ~s(phx-click="wipe"))) == 2
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/armchair_metropolist_web/live/simulator_live_test.exs`
Expected: FAIL — `#reset-city` and `#collapse-banner` are not in the DOM, and
`render_click(view, "wipe")` raises "no matching event handler".

- [ ] **Step 3: Write minimal implementation**

In `simulator_live.ex`:

Add the alias, beside the existing entity aliases:

```elixir
  alias ArmchairMetropolist.Domain.Entities.SimulationMetrics
```

Add the event handler, after `handle_event("demolish", …)`:

```elixir
  def handle_event("wipe", _params, socket) do
    :ok = CityEngine.reset(socket.assigns.city_id)

    {:noreply, stream(socket, :nodes, [], reset: true)}
  end
```

Add the broadcast handler, after `handle_info({:city_node_removed, id}, …)`:

```elixir
  def handle_info(:city_reset, socket) do
    {:noreply, stream(socket, :nodes, [], reset: true)}
  end
```

In `render/1`, add the actions slot as the **first** child of `<Layouts.app …>`, before
the `<h1 class="sr-only">`:

```heex
      <:actions>
        <%!-- `min-h-6` rather than bare `btn-xs`: daisyUI's xs button is 21px tall and
              WCAG 2.2 AA wants a 24x24 target. `btn-sm` clears that at 35px but costs
              48px of width, which is what pushes the wordmark over at a 375px viewport.

              `text-white` rather than daisyUI's own error foreground: measured,
              `--color-error-content` on `--color-error` is 4.08:1 in both themes, under
              the 4.5 floor for small text. White is 4.60:1 and passes in both. --%>
        <button
          :if={show_reset?(@metrics)}
          id="reset-city"
          type="button"
          class="btn btn-xs btn-error text-white min-h-6"
          phx-click="wipe"
          title="Clear every block and start a new city — this cannot be undone"
        >
          Reset
        </button>
      </:actions>
```

And add the banner on the line immediately after `<h1 class="sr-only">Armchair
Metropolist</h1>`, above the long comment that introduces the
`<div class="flex flex-wrap items-start gap-4">` row (leave that comment attached to the
element it explains):

```heex
      <.collapse_banner metrics={@metrics} width={@width} cell_size={@cell_size} />
```

Add the component and helper, after `render/1` and before `legend/1`:

```elixir
  # Rendered above the grid, deliberately outside the `<aside>`: the sidebar's width sets
  # the wrap thresholds documented in `render/1`, and this block's prose is far wider than
  # anything already in there.
  #
  # Status only. It names the header's Reset button rather than rendering a second copy of
  # it — `show_reset?/1` is a strict superset of `stalled`, so the control is guaranteed to
  # be on screen whenever this is.
  attr :metrics, :map, required: true
  attr :width, :integer, required: true
  attr :cell_size, :integer, required: true

  defp collapse_banner(assigns) do
    ~H"""
    <%!-- The grid's own width expression, so the two cannot drift apart. `max-w-full`
          and `box-border` are both required: without the first this overflows a narrow
          viewport instead of clamping, and without the second the padding and border
          push it past the grid's right edge at every width. --%>
    <div
      :if={@metrics.stalled}
      id="collapse-banner"
      class={[
        "box-border max-w-full rounded-lg border border-l-4 px-4 py-3",
        if(SimulationMetrics.game_over?(@metrics),
          do: "border-error bg-error/10",
          else: "border-warning bg-warning/10"
        )
      ]}
      style={"width: #{@width * @cell_size}px"}
    >
      <%!-- The headline is a verdict and the sentence under it is the mechanism, in that
            order. The verdict is earned rather than asserted: ticks are ignored while
            stalled, so health, tick and money are all constant, and both commands cost
            more than the treasury holds. --%>
      <p :if={SimulationMetrics.game_over?(@metrics)} class="font-semibold">
        Game over — this city is dead.
      </p>
      <p :if={not SimulationMetrics.game_over?(@metrics)} class="font-semibold">
        City stalled — nothing is changing on its own.
      </p>

      <p :if={SimulationMetrics.game_over?(@metrics)} class="text-xs opacity-80">
        Every block is dead and starving, so the clock has stopped. Building costs at least
        {trunc(Node.cheapest_construction_cost())} and demolishing costs
        {trunc(Node.demolition_cost())}, and the treasury holds {trunc(@metrics.money)} — so
        nothing can restart it. <strong>Reset</strong>
        in the header clears the grid and starts a new city. This cannot be undone.
      </p>
      <p :if={not SimulationMetrics.game_over?(@metrics)} class="text-xs opacity-80">
        Every block is dead and starving, so the clock has stopped. The treasury still holds
        {trunc(@metrics.money)}: building always restarts it, and demolishing can too. Or <strong>Reset</strong>
        in the header to start over.
      </p>
    </div>
    """
  end

  # No living housing, and the reset would actually change something.
  #
  # The second disjunct is not redundant. Demolishing costs 10 and clears a node, so a
  # player can spend down to an empty grid holding 9: no nodes, so the city is not stalled
  # and there is no banner; nothing costs 10 or less; and an empty grid earns nothing,
  # forever. Without it that position has no affordance at all. With it, the button still
  # stays hidden on a fresh city, where a reset is a no-op — which is the only reason the
  # gate is not the bare `not housing_alive`.
  #
  # `bankrupt` rather than a second comparison against `Node.cheapest_action_cost/0`, so
  # the threshold has exactly one reader.
  defp show_reset?(metrics) do
    not metrics.housing_alive and (metrics.node_count > 0 or metrics.bankrupt)
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/armchair_metropolist_web/`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
mix precommit
git add lib/armchair_metropolist_web/live/simulator_live.ex test/armchair_metropolist_web/live/simulator_live_test.exs
git commit -m "feat(web): add the Reset control and the collapse banner"
```

---

### Task 11: Document the end state in the playing guide

**Files:**
- Modify: `docs/PLAYING.md`
- Test: `test/docs/playing_guide_test.exs` (must stay green **without** regeneration)

**Interfaces:**
- Consumes: everything above.
- Produces: nothing code-facing.

- [ ] **Step 1: Confirm the guide is currently green**

Run: `mix test test/docs/playing_guide_test.exs`
Expected: PASS. This is the baseline — the generated blocks are computed from
`SimulationCalculator.advance_tick/1` directly and never touch `CityEngine`, so the
freeze cannot move any of them. If this is already red, stop and report; that is a
different problem from this task.

- [ ] **Step 2: Re-read the two passages this change bears on**

Read `docs/PLAYING.md` around the demolition-as-escape paragraph (~line 26, "it is how
you get out of a collapse — but at the fee above") and the 19-dead-blocks simulation
(~line 174, "every node's health is still 0.0 after 150 ticks").

- The demolition paragraph already states the bankruptcy threshold in player language
  and is correct. The new section should point at it, not restate it.
- The 150-tick sentence is still true of the calculator that produced it, but a player
  now never watches 150 such ticks, because the engine stops. Adjust its framing only —
  do not touch the arithmetic.

- [ ] **Step 3: Add the new section**

Append a section near the end of `docs/PLAYING.md`, matching the file's existing prose
style. State mechanisms, not verdicts:

```markdown
## When the city stops

A city **stalls** when every block sits at zero health with at least one of its inputs
short. At that point nothing changes on its own: production scales with health and so is
zero, consumption does not scale and so is unchanged, and each tick recomputes the same
result. The simulation stops advancing, and the tick counter stops with it.

Stalling is not the same as being beyond help, and the difference is the treasury. A
frozen city's balance is frozen too — it no longer drains to the upkeep of water plants,
transit hubs and parks — so whatever was in the bank when the city stalled is still there.

**Building anything restarts the clock; demolishing restarts it only if it changes the
arithmetic.** A new block goes up at full health, and "every block at zero" is what the
stall is, so one placement of any type is enough to start the ticks again — though the new
block is then subject to the same shortage that killed the rest, and a city that is still
short will stall again once it dies. A demolition restarts the clock only when it takes
what is left back inside the free baseline: tear one house out of three and the remaining
two are supplied and heal, tear one out of five and the remaining four are still over the
line and nothing moves.

Not every dead-looking city is stalled. One or two houses alone recover from zero health
with an empty treasury: each draws 15 power against the free baseline of 40, so at `15n ≤
40` they are fully supplied even while dead, and they regenerate. Three do not — 45 against
40 — and that is the cliff.

**Game over** is the narrower case: the city has stalled *and* holds less than 10. The
cheapest thing you can do is demolish, at 10, and the cheapest thing you can build is a
house, at 15, so below 10 no command is affordable — and because the clock has stopped, the
balance will never rise again. Nothing can change. See "Running out of money" above: the
escape has to be bought while there is still something to buy it with.

Both states put a **Reset** button in the page header, beside the theme toggle. It clears every
block, returns the treasury to the opening grant, sets the tick back to zero and discards
the stored city. There is no confirmation and no undo.
```

- [ ] **Step 4: Verify the guide test is still green**

Run: `mix test test/docs/playing_guide_test.exs`
Expected: PASS, with no regeneration. The new prose sits outside every generated block.
If it fails, that is a real finding — read the diff the test prints rather than running
`REGENERATE_PLAYING_GUIDE=1`.

- [ ] **Step 5: Run the whole suite and commit**

Run: `mix check`

```bash
git add docs/PLAYING.md
git commit -m "docs: explain stalling, game over, and the reset"
```

---

## Notes for the executor

- **Task order matters.** 1 → 2 → 3 (metrics stack up), 5 → 7 → 8 (reset stack), 6 before 8 (the engine needs `delete/1`), 9 before 10 (the slot must exist before it is filled). 4 before 8 as well: Task 8's tests reuse the `dead_city/2` helper Task 4 adds to `city_engine_test.exs`. Otherwise 4 is independent once 3 lands. 11 is last.
- **`mix precommit` before every commit**, not just at the end. It runs
  `compile --warnings-as-errors`, which is where a `Boundary` violation surfaces. Sobelow
  is not in `precommit` but *is* in `.githooks/pre-commit`, so it gates the commit itself —
  see Global Constraints, and do not check `.git/hooks` to confirm that.
- **The `amenity` → `derived` rename in Task 3 is the one change with reach, and its two
  casualties are named in that task.** `simulation_metrics_test.exs` has exactly two
  callers of `build/3` — every other call site in the tree uses `build/2` and picks up the
  default — and both are rewritten in Task 3, Step 1. If a *third* file turns up failing,
  fix it at the source rather than in the assertion.
