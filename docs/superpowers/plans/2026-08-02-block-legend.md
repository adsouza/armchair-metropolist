# Block Legend Sidebar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Place button row and the Metrics block with a collapsible
right-hand sidebar showing, per node type, how many are placed and their net effect on
each of the four resources — rated and health-scaled — plus a city totals row.

**Architecture:** The per-type aggregation is computed in the Domain, as a new
`by_type` field on `SimulationMetrics`, and reaches the view over the existing
`{:city_metrics, …}` PubSub broadcast. `CityEngine` starts broadcasting that message on
place and demolish as well as on tick, so the legend updates on the action rather than
up to a second later. No simulation rule changes.

**Tech Stack:** Elixir, Phoenix LiveView 1.2, HEEx, Tailwind + daisyUI, ExUnit.

**Spec:** `docs/superpowers/specs/2026-08-02-block-legend-design.md`

**Revised** after a Codex review of the first draft, which found two defects that would
have produced deterministically failing tests, plus one shipped bug the plan had
inherited. Each fix is marked `[review]` at the step that carries it.

## Global Constraints

- **Elixir floor is `~> 1.18`.** Do not use standard-library functions introduced after
  1.18. This project has already shipped one bug of exactly this kind (`Enum.sum_by/2`,
  added in 1.18, under a `~> 1.17` claim). CI builds the floor, so a newer function
  fails there and not locally.
- **`mix check` must exit 0.** It runs `format --check-formatted`, `compile --force
  --warnings-as-errors`, `sobelow`, `deps.audit`, then `test --cover` with a **90%**
  coverage threshold. `--warnings-as-errors` is what enforces `boundary`, whose
  violations are only warnings.
- **`Domain` must stay pure.** `domain_purity_test.exs` reads compiled BEAM imports and
  fails on `GenServer`, `Agent`, `Task`, `Process`, and `:erlang` functions named
  `spawn`, `send`, `self`, `exit`, `monitor`.
- **`ArmchairMetropolistWeb` may call `Domain.Entities.Node`** (it is exported) but
  **may not** reach `Domain.Services`. Do not add domain arithmetic to the template.
- **LiveView tests use `element/2` and `has_element?/2`, not `html =~`.** Required by
  `AGENTS.md:376`. Give every element you assert on a stable `id` or `data-` attribute.
  The first draft of this plan used raw-HTML matching and produced an assertion that
  could not fail; see Task 3, Step 1.
- **Never write a `refute` without first asserting the positive case** in the same
  test. A refutation against something that never occurs is always true.
- **A test you have not seen fail is not a test.** Every task ends by breaking the code
  under test and confirming the new test goes red. See `TESTING.md`.
- Pre-commit and pre-push hooks run automatically. Do not use `--no-verify`.

### A standing conflict, decided deliberately

`AGENTS.md:35` says to write bespoke Tailwind rather than use daisyUI. **This plan uses
daisyUI component classes anyway** (`btn`, `table`), because the rule and this codebase
already disagree: daisyUI is installed (`@plugin "daisyui/..."` in `assets/css/app.css`)
and `simulator_live.ex`, `layouts.ex` and `core_components.ex` all use its classes
today. Building this one panel in bespoke Tailwind would leave it visually inconsistent
with every neighbouring control, and converting the whole app is separate work.

If you would rather honour the rule, that is a legitimate call — but make it for the
whole UI, not for this panel alone.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `lib/armchair_metropolist/domain/entities/simulation_metrics.ex` | aggregate per-tick figures, now including the per-type breakdown | modify |
| `test/armchair_metropolist/domain/entities/simulation_metrics_test.exs` | unit tests for that aggregation | modify |
| `lib/armchair_metropolist/infrastructure/simulation/city_engine.ex` | broadcast fresh metrics on place and demolish; correct a stale moduledoc | modify |
| `test/armchair_metropolist/infrastructure/simulation/city_engine_test.exs` | tests for those broadcasts | modify |
| `lib/armchair_metropolist_web/live/simulator_live.ex` | render the grid and the sidebar; own the collapse state; correct a stale moduledoc | modify |
| `test/armchair_metropolist_web/live/simulator_live_test.exs` | LiveView tests for the sidebar | modify |
| `docs/PLAYING.md` | player-facing description of the controls | modify |

The sidebar markup lives in a private function component inside `SimulatorLive` rather
than a new module: it is used in exactly one place and depends on that view's assigns.

---

## Task 1: `by_type` breakdown in `SimulationMetrics`

**Files:**
- Modify: `lib/armchair_metropolist/domain/entities/simulation_metrics.ex`
- Test: `test/armchair_metropolist/domain/entities/simulation_metrics_test.exs`

**Interfaces:**
- Consumes: `Node.types/0`, `Node.production/1`, `Node.consumption/1`,
  `Node.effective_production/1` — all already public on
  `ArmchairMetropolist.Domain.Entities.Node`.
- Produces: `%SimulationMetrics{by_type: %{Node.node_type() => type_stats()}}` where

  ```elixir
  @type type_stats :: %{
          count: non_neg_integer(),
          rated_production: %{Node.resource() => float()},
          actual_production: %{Node.resource() => float()},
          consumption: %{Node.resource() => float()}
        }
  ```

  `by_type` has an entry for **every** type in `Node.types/0`, present or not.
  The inner maps carry a key **only** for resources that type's base tables mention,
  with value `0.0` when no nodes of that type are placed. Task 3 relies on that: a
  missing key means "does not interact" and renders `—`, which is different from a
  present key holding `0.0`.

- [ ] **Step 1: Write the failing tests**

Append inside the existing `defmodule ... do` in
`test/armchair_metropolist/domain/entities/simulation_metrics_test.exs`, before the
final `end`:

```elixir
  describe "by_type" do
    test "counts each type and includes types that are absent" do
      map =
        CityMap.new(40, 30)
        |> CityMap.put_node(Node.new(0, 0, :residential))
        |> CityMap.put_node(Node.new(1, 0, :residential))
        |> CityMap.put_node(Node.new(2, 0, :power_plant))

      by_type = SimulationMetrics.build(map, stats()).by_type

      assert by_type.residential.count == 2
      assert by_type.power_plant.count == 1

      # Absent types still get a row, so the legend does not reflow as a city grows.
      assert by_type.industrial.count == 0
      assert Enum.sort(Map.keys(by_type)) == Enum.sort(Node.types())
    end

    test "rated production is count x base and ignores health" do
      map =
        CityMap.new(40, 30)
        |> CityMap.put_node(%Node{Node.new(0, 0, :power_plant) | health: 25.0})
        |> CityMap.put_node(%Node{Node.new(1, 0, :power_plant) | health: 100.0})

      by_type = SimulationMetrics.build(map, stats()).by_type

      assert_in_delta by_type.power_plant.rated_production.power, 240.0, 0.001
    end

    test "actual production is health-scaled and diverges from rated" do
      # This divergence is the whole point of the legend: production scales with
      # health, consumption does not, so a damaged city shows supply falling against
      # steady demand.
      map =
        CityMap.new(40, 30)
        |> CityMap.put_node(%Node{Node.new(0, 0, :power_plant) | health: 25.0})
        |> CityMap.put_node(%Node{Node.new(1, 0, :power_plant) | health: 100.0})

      by_type = SimulationMetrics.build(map, stats()).by_type

      assert_in_delta by_type.power_plant.actual_production.power, 150.0, 0.001

      assert by_type.power_plant.actual_production.power <
               by_type.power_plant.rated_production.power,
             "a damaged producer must report less actual output than rated"
    end

    test "consumption is count x base and does not scale with health" do
      map =
        CityMap.new(40, 30)
        |> CityMap.put_node(%Node{Node.new(0, 0, :residential) | health: 1.0})
        |> CityMap.put_node(%Node{Node.new(1, 0, :residential) | health: 100.0})

      by_type = SimulationMetrics.build(map, stats()).by_type

      assert_in_delta by_type.residential.consumption.power, 30.0, 0.001
      assert_in_delta by_type.residential.consumption.water, 24.0, 0.001
    end

    test "a key is present only where the type touches that resource" do
      by_type = SimulationMetrics.build(CityMap.new(40, 30), stats()).by_type

      # A road hub produces traffic and consumes power and waste, but never water.
      assert Map.has_key?(by_type.road_hub.rated_production, :traffic)
      assert Map.has_key?(by_type.road_hub.consumption, :power)
      refute Map.has_key?(by_type.road_hub.consumption, :water)
      refute Map.has_key?(by_type.road_hub.rated_production, :water)
    end

    test "an empty city reports every type at zero rather than an empty map" do
      by_type = SimulationMetrics.build(CityMap.new(40, 30), stats()).by_type

      assert by_type.power_plant.count == 0
      assert by_type.power_plant.rated_production.power == 0.0
      assert by_type.power_plant.actual_production.power == 0.0
      assert by_type.power_plant.consumption.water == 0.0
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/armchair_metropolist/domain/entities/simulation_metrics_test.exs`
Expected: FAIL — `key :by_type not found`.

- [ ] **Step 3: Add the field and the aggregation**

In `lib/armchair_metropolist/domain/entities/simulation_metrics.ex`, add the `Node`
alias beside the existing `CityMap` one:

```elixir
  alias ArmchairMetropolist.Domain.Entities.CityMap
  alias ArmchairMetropolist.Domain.Entities.Node
```

Add the type above the existing `@type t`:

```elixir
  @typedoc """
  One type's contribution. A key is present in the inner maps only where that node
  type's base tables mention the resource, so a missing key means "does not interact"
  while a present `0.0` means "nets to zero" — the legend renders those differently.
  """
  @type type_stats :: %{
          count: non_neg_integer(),
          rated_production: %{Node.resource() => float()},
          actual_production: %{Node.resource() => float()},
          consumption: %{Node.resource() => float()}
        }
```

Add `by_type` to `@type t` and to `defstruct`:

```elixir
  @type t :: %__MODULE__{
          tick: non_neg_integer(),
          resources: %{optional(atom()) => resource_stats()},
          node_count: non_neg_integer(),
          avg_health: float(),
          offline_count: non_neg_integer(),
          by_type: %{Node.node_type() => type_stats()}
        }

  defstruct tick: 0,
            resources: %{},
            node_count: 0,
            avg_health: 0.0,
            offline_count: 0,
            by_type: %{}
```

Set it in `build/2`:

```elixir
    %__MODULE__{
      tick: city_map.tick,
      resources: resources,
      node_count: node_count,
      avg_health: avg_health,
      offline_count: offline_count,
      by_type: build_by_type(nodes)
    }
```

Add these private functions before the module's final `end`:

```elixir
  # Every type gets an entry, present or not, so the legend renders a stable set of
  # rows. Rated and actual are kept apart rather than reduced to one figure: production
  # scales with health and consumption does not, and that divergence is what makes a
  # collapse visible.
  defp build_by_type(nodes) do
    grouped = Enum.group_by(nodes, & &1.type)

    Map.new(Node.types(), fn type ->
      of_type = Map.get(grouped, type, [])

      {type,
       %{
         count: length(of_type),
         rated_production: scale(Node.production(type), length(of_type)),
         actual_production: sum_actual_production(type, of_type),
         consumption: scale(Node.consumption(type), length(of_type))
       }}
    end)
  end

  defp scale(table, count) do
    Map.new(table, fn {resource, amount} -> {resource, amount * count} end)
  end

  # Keyed off the type's *base* production table rather than the nodes, so the keys are
  # the same whether or not any are placed.
  defp sum_actual_production(type, nodes) do
    type
    |> Node.production()
    |> Map.new(fn {resource, _base} ->
      total =
        Enum.reduce(nodes, 0.0, fn node, acc ->
          acc + Map.get(Node.effective_production(node), resource, 0.0)
        end)

      {resource, total}
    end)
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/armchair_metropolist/domain/entities/simulation_metrics_test.exs`
Expected: PASS, including the pre-existing tests.

- [ ] **Step 5: Mutation-verify the divergence test**

Temporarily make `sum_actual_production/2` ignore health:

```elixir
      total =
        Enum.reduce(nodes, 0.0, fn _node, acc ->
          acc + Map.get(Node.production(type), resource, 0.0)
        end)
```

Run: `mix test test/armchair_metropolist/domain/entities/simulation_metrics_test.exs`
Expected: FAIL on "actual production is health-scaled and diverges from rated".
Restore, and confirm PASS.

- [ ] **Step 6: Run the whole gate**

Run: `mix check`
Expected: exit 0.

- [ ] **Step 7: Commit**

```bash
git add lib/armchair_metropolist/domain/entities/simulation_metrics.ex \
        test/armchair_metropolist/domain/entities/simulation_metrics_test.exs
git commit -m "feat(domain): add a per-type breakdown to SimulationMetrics"
```

---

## Task 2: Broadcast fresh metrics on place and demolish `[review]`

**Files:**
- Modify: `lib/armchair_metropolist/infrastructure/simulation/city_engine.ex`
- Test: `test/armchair_metropolist/infrastructure/simulation/city_engine_test.exs`

**Interfaces:**
- Consumes: `by_type` from Task 1, indirectly — this task does not read it, but the
  metrics it broadcasts carry it.
- Produces: a `{:city_metrics, %SimulationMetrics{}}` broadcast on the
  `"city_simulation"` topic after every **successful** place and demolish. Task 3's
  legend depends on this to show counts that change when you click.

**Why this task exists.** `handle_call({:place, …})` already recomputes
`summarize(city_map)` into its own state, but broadcasts only `{:city_node_placed,
node}`. So a subscriber's metrics stay stale until the next tick — up to a second in
the app, and **forever in tests**, which do not start `TickServer`. Without this, the
legend's counts would not move when you place a block, and Task 3's tests could not
pass. Found by review of the first draft of this plan.

- [ ] **Step 1: Write the failing tests**

Add to `test/armchair_metropolist/infrastructure/simulation/city_engine_test.exs`,
inside the existing describe block that covers place/demolish (or a new one):

```elixir
    test "placing broadcasts fresh metrics, not just the node" do
      StubSnapshotRepository.set_initial({:error, :not_found})
      start_supervised!(CityEngine)
      Phoenix.PubSub.subscribe(ArmchairMetropolist.PubSub, "city_simulation")

      assert {:ok, _node} = CityEngine.place(0, 0, :power_plant)

      assert_receive {:city_node_placed, _node}

      assert_receive {:city_metrics, metrics}
      assert metrics.node_count == 1

      assert metrics.by_type.power_plant.count == 1,
             "a subscriber must see the new node reflected in metrics immediately, " <>
               "not only after the next tick"
    end

    test "demolishing broadcasts fresh metrics, not just the id" do
      StubSnapshotRepository.set_initial({:error, :not_found})
      start_supervised!(CityEngine)
      assert {:ok, _node} = CityEngine.place(0, 0, :power_plant)

      Phoenix.PubSub.subscribe(ArmchairMetropolist.PubSub, "city_simulation")
      assert {:ok, "0:0"} = CityEngine.demolish(0, 0)

      assert_receive {:city_node_removed, "0:0"}

      assert_receive {:city_metrics, metrics}
      assert metrics.node_count == 0
      assert metrics.by_type.power_plant.count == 0
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/armchair_metropolist/infrastructure/simulation/city_engine_test.exs`
Expected: FAIL — `assert_receive {:city_metrics, metrics}` times out, because only the
node message is broadcast today.

- [ ] **Step 3: Broadcast the metrics**

In `lib/armchair_metropolist/infrastructure/simulation/city_engine.ex`, in the
successful branch of `handle_call({:place, …})`, replace:

```elixir
        broadcast({:city_node_placed, node})
        {:reply, {:ok, node}, %{state | city_map: city_map, metrics: summarize(city_map)}}
```

with:

```elixir
        metrics = summarize(city_map)
        broadcast({:city_node_placed, node})
        # Commands change the city, so subscribers need the new figures now. Without
        # this the legend's counts would not move until the next tick — and in tests,
        # where no clock runs, never.
        broadcast({:city_metrics, metrics})
        {:reply, {:ok, node}, %{state | city_map: city_map, metrics: metrics}}
```

And in the successful branch of `handle_call({:demolish, …})`, replace:

```elixir
        broadcast({:city_node_removed, node_id})
        {:reply, {:ok, node_id}, %{state | city_map: city_map, metrics: summarize(city_map)}}
```

with:

```elixir
        metrics = summarize(city_map)
        broadcast({:city_node_removed, node_id})
        broadcast({:city_metrics, metrics})
        {:reply, {:ok, node_id}, %{state | city_map: city_map, metrics: metrics}}
```

- [ ] **Step 4: Correct the stale moduledoc `[review]`**

`CityEngine`'s moduledoc still describes behaviour that `SummarizeCity` fixed — it
claims `snapshot/0` reports an empty `resources` map until the first tick, which
`city_engine_test.exs:97` explicitly disproves. Replace the section headed
`## metrics.resources before the first tick` with:

```elixir
  ## `metrics.resources` at hydration

  `snapshot/0` reports full resource statistics from the moment the engine hydrates,
  before any tick has run. `Infrastructure` cannot reach `SimulationCalculator`
  directly — the boundary graph forbids it — so the figures come via
  `UseCases.SummarizeCity`. This used to be an empty map, and a LiveView mounting in
  that window had nothing to render; `city_engine_test.exs` has a regression test for
  it.
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/armchair_metropolist/infrastructure/simulation/city_engine_test.exs`
Expected: PASS, including the pre-existing regression test.

- [ ] **Step 6: Mutation-verify**

Remove the `broadcast({:city_metrics, metrics})` line from the place branch only.
Run the file again.
Expected: FAIL on "placing broadcasts fresh metrics, not just the node".
Restore, confirm PASS.

- [ ] **Step 7: Run the whole gate**

Run: `mix check`
Expected: exit 0.

- [ ] **Step 8: Commit**

```bash
git add lib/armchair_metropolist/infrastructure/simulation/city_engine.ex \
        test/armchair_metropolist/infrastructure/simulation/city_engine_test.exs
git commit -m "fix(engine): broadcast fresh metrics on place and demolish"
```

---

## Task 3: The legend sidebar

**Files:**
- Modify: `lib/armchair_metropolist_web/live/simulator_live.ex`
- Test: `test/armchair_metropolist_web/live/simulator_live_test.exs`

**Interfaces:**
- Consumes: `@metrics.by_type` (Task 1) and the `{:city_metrics, …}` broadcasts on
  place and demolish (Task 2). Also `@metrics.resources`, which is **populated from
  mount** — see Task 2, Step 4.
- Produces: a private function component `legend/1` taking `metrics`, `node_types` and
  `selected_type`. Task 4 wraps its call site in a collapse toggle.

- [ ] **Step 1: Write the failing tests `[review]`**

These use `element/2` and `has_element?/2` rather than matching raw HTML, per
`AGENTS.md:376`. The first draft used `html =~` and produced an assertion that passed
regardless of the value under test.

Append inside the existing `defmodule ... do` in
`test/armchair_metropolist_web/live/simulator_live_test.exs`, before the final `end`:

```elixir
  describe "legend" do
    test "shows how many of each type are placed, updating as you place", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Every type has a row from the start, including ones with nothing placed.
      assert has_element?(view, "#legend-row-industrial")
      assert has_element?(view, ~s{#legend-row-power_plant[data-count="0"]})

      view
      |> element(~s{button[phx-click="select_type"][phx-value-type="power_plant"]})
      |> render_click()

      view |> element(~s{[phx-click="place"][phx-value-x="1"][phx-value-y="1"]}) |> render_click()
      view |> element(~s{[phx-click="place"][phx-value-x="2"][phx-value-y="1"]}) |> render_click()

      # Depends on Task 2: without the command-time broadcast this stays at 0.
      assert has_element?(view, ~s{#legend-row-power_plant[data-count="2"]})
    end

    test "a producing cell shows the type's net effect on that resource", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> element(~s{button[phx-click="select_type"][phx-value-type="power_plant"]})
      |> render_click()

      view |> element(~s{[phx-click="place"][phx-value-x="3"][phx-value-y="3"]}) |> render_click()

      # One power plant: power +120, water -20.
      assert view |> element(~s{[data-cell="power_plant-power"]}) |> render() =~ "+120"
      assert view |> element(~s{[data-cell="power_plant-water"]}) |> render() =~ "-20"
    end

    test "a resource the type never touches shows an em dash, not a zero", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Positive case first: a road hub does consume power, so that cell holds a number.
      assert view |> element(~s{[data-cell="road_hub-power"]}) |> render() =~ "0"

      # It never touches water, and that must read differently from "nets to zero".
      water = view |> element(~s{[data-cell="road_hub-water"]}) |> render()
      assert water =~ "—"
      refute water =~ "0"
    end

    test "the totals row reports supply, demand and satisfaction per resource",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      send(view.pid, {:city_metrics, metrics_with_distinct_satisfaction()})
      render(view)

      assert view |> element(~s{[data-total="power"]}) |> render() =~ "100.0%"
      assert view |> element(~s{[data-total="water"]}) |> render() =~ "50.0%"
    end

    test "satisfaction appears only in the totals row, not in a Metrics list",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      send(view.pid, {:city_metrics, metrics_with_distinct_satisfaction()})
      render(view)

      # Positive case: the Metrics block survived the move into the sidebar.
      assert has_element?(view, "#metrics-tick")

      # And the old per-resource satisfaction list is gone, so the figure is not
      # rendered twice.
      refute has_element?(view, "#metrics-resources")
    end
  end

  # Distinct values per resource on purpose: with every resource at 1.0 a test cannot
  # tell one totals cell from another, and "appears once" assertions become impossible.
  defp metrics_with_distinct_satisfaction do
    alias ArmchairMetropolist.Domain.Entities.{CityMap, SimulationMetrics}

    stat = fn satisfaction ->
      %{supplied: 40.0, demanded: 40.0, deficit: 0.0, satisfaction: satisfaction}
    end

    base = SimulationMetrics.build(CityMap.new(40, 30), %{})

    %{
      base
      | tick: 3,
        resources: %{
          power: stat.(1.0),
          water: stat.(0.5),
          waste: stat.(0.75),
          traffic: stat.(0.25)
        }
    }
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/armchair_metropolist_web/live/simulator_live_test.exs`
Expected: FAIL — no `#legend-row-*` elements exist.

- [ ] **Step 3: Replace the Place row and Metrics block with the sidebar `[review]`**

In `lib/armchair_metropolist_web/live/simulator_live.ex`, delete the two `<div
class="mb-4">` blocks holding **Place** and **Metrics**, then replace from the
`<h1 class="sr-only">` line through the grid's closing `</div>` with:

```heex
      <h1 class="sr-only">Armchair Metropolist</h1>

      <div class="flex flex-col items-start gap-4 min-[1450px]:flex-row">
        <div
          class="relative shrink-0 border border-base-300"
          style={"width: #{@width * @cell_size}px; height: #{@height * @cell_size}px;"}
        >
          <div
            :for={{x, y} <- @grid_cells}
            class="absolute border border-base-200 cursor-pointer"
            style={cell_style(x, y, @cell_size)}
            phx-click="place"
            phx-value-x={x}
            phx-value-y={y}
            title={"place #{@selected_type} at #{x}:#{y}"}
          >
          </div>

          <div id="nodes" phx-update="stream">
            <div
              :for={{dom_id, node} <- @streams.nodes}
              id={dom_id}
              class={[
                "absolute flex cursor-pointer items-center justify-center text-[8px]",
                status_class(node.status)
              ]}
              style={cell_style(node.x, node.y, @cell_size)}
              phx-click="demolish"
              phx-value-x={node.x}
              phx-value-y={node.y}
              title={"#{node.id} · #{node.type} · #{node.status} (#{round(node.health)}%) — click to demolish"}
            >
              {short_label(node.type)}
            </div>
          </div>
        </div>

        <.legend metrics={@metrics} node_types={@node_types} selected_type={@selected_type} />
      </div>
```

Two details, both from review:

* `shrink-0` on the grid. It is absolutely positioned at a fixed 960px and cannot
  reflow, so flex must never be allowed to squeeze its container.
* `min-[1450px]:flex-row`, not `lg:`. At `lg` (1024px) the page has 1024 − 64 of
  padding = **960px**, exactly the grid's width, so a sidebar beside it would overflow.
  960 grid + 16 gap + ~410 sidebar + 64 padding ≈ 1450.

- [ ] **Step 4: Add the `legend/1` component `[review]`**

Add after `render/1` and before `cell_style/3`:

```elixir
  # The four resource columns are fixed and identical on every row, including where a
  # type does not touch a resource. Aligned columns are the feature: the question a
  # player has is "water is short, who is drinking it?", answered by reading one column
  # down all seven types. Per-row chips would be narrower and unreadable for that.
  @resources [:power, :water, :waste, :traffic]

  attr :metrics, :map, required: true
  attr :node_types, :list, required: true
  attr :selected_type, :atom, required: true

  defp legend(assigns) do
    assigns = assign(assigns, :resources, @resources)

    ~H"""
    <div class="w-full min-[1450px]:w-auto">
      <h2 class="font-semibold mb-2">Types</h2>

      <div class="overflow-x-auto">
        <table class="table table-xs">
          <thead>
            <tr>
              <th class="text-left">type</th>
              <th class="text-right">#</th>
              <th :for={resource <- @resources} class="text-right">{resource}</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={type <- @node_types}
              id={"legend-row-#{type}"}
              data-count={@metrics.by_type[type].count}
              class={type == @selected_type && "bg-primary/20"}
            >
              <td class="text-left">
                <%!-- A real button, not a clickable <tr>: the row must stay reachable
                      by keyboard and expose button semantics to assistive tech. --%>
                <button
                  type="button"
                  class="btn btn-ghost btn-xs w-full justify-start"
                  phx-click="select_type"
                  phx-value-type={type}
                  aria-pressed={to_string(type == @selected_type)}
                >
                  {type}
                </button>
              </td>
              <td class="text-right tabular-nums">{@metrics.by_type[type].count}</td>
              <td
                :for={resource <- @resources}
                data-cell={"#{type}-#{resource}"}
                class="text-right tabular-nums"
              >
                {net_cell(@metrics.by_type[type], resource)}
              </td>
            </tr>
          </tbody>
          <tfoot>
            <tr id="legend-totals">
              <th class="text-left" colspan="2">supplied / demanded</th>
              <th
                :for={resource <- @resources}
                data-total={resource}
                class="text-right tabular-nums"
              >
                {totals_cell(@metrics.resources, resource)}
              </th>
            </tr>
          </tfoot>
        </table>
      </div>

      <p class="mt-1 text-xs opacity-60">
        Totals include the free baseline of 40 per resource, which belongs to no type.
      </p>

      <div class="mt-4">
        <h2 class="font-semibold mb-2">Metrics</h2>
        <p id="metrics-tick">Tick: {@metrics.tick}</p>
        <p id="metrics-nodes">Nodes: {@metrics.node_count}</p>
        <p id="metrics-health">Avg health: {Float.round(@metrics.avg_health, 1)}</p>
        <p id="metrics-offline">Offline: {@metrics.offline_count}</p>
      </div>
    </div>
    """
  end

  # A missing key means the type does not interact with the resource at all, which reads
  # differently from a net of zero — hence the em dash rather than "0".
  #
  # Rated and actual are shown together only when they differ, so a healthy city reads
  # cleanly and divergence is what draws the eye.
  defp net_cell(stats, resource) do
    produced = Map.get(stats.rated_production, resource)
    actual = Map.get(stats.actual_production, resource)
    consumed = Map.get(stats.consumption, resource)

    cond do
      is_nil(produced) and is_nil(consumed) ->
        "—"

      is_nil(produced) ->
        signed(-consumed)

      true ->
        rated_net = produced - (consumed || 0.0)
        actual_net = actual - (consumed || 0.0)

        if abs(rated_net - actual_net) < 0.05,
          do: signed(rated_net),
          else: "#{signed(rated_net)} → #{signed(actual_net)}"
    end
  end

  # `resources` is populated from mount via SummarizeCity, so there is no empty-map
  # case to guard here beyond ordinary defensiveness.
  defp totals_cell(resources, resource) do
    case Map.get(resources, resource) do
      nil ->
        "—"

      stats ->
        "#{round(stats.supplied)}/#{round(stats.demanded)} · " <>
          "#{Float.round(stats.satisfaction * 100, 1)}%"
    end
  end

  defp signed(value) do
    rounded = round(value)
    if rounded > 0, do: "+#{rounded}", else: to_string(rounded)
  end
```

- [ ] **Step 5: Correct the stale moduledoc `[review]`**

`SimulatorLive`'s moduledoc carries the same false claim as the engine's did. Replace
the section headed `## metrics.resources before the first tick` with:

```elixir
  ## Where the figures come from

  `CityEngine.snapshot/0` returns full resource statistics at mount, before any tick —
  it computes them through `UseCases.SummarizeCity`, since `Infrastructure` may not
  reach `Domain.Services`. The engine also broadcasts `{:city_metrics, …}` after every
  successful place and demolish, so the legend's counts move on the click rather than
  on the next tick.
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `mix test test/armchair_metropolist_web/live/simulator_live_test.exs`
Expected: PASS.

- [ ] **Step 7: Mutation-verify the count assertion**

Temporarily hard-code `data-count="0"` in `legend/1`.
Run the file again.
Expected: FAIL on "shows how many of each type are placed, updating as you place".
Restore, confirm PASS.

- [ ] **Step 8: Verify in a browser**

Use the Browser tool — `preview_start` with name `armchair-metropolist` from
`.claude/launch.json`, never `mix phx.server` via Bash.

1. Read the console for errors — expect none.
2. Place two power plants and one residential; confirm counts and the `power` column
   change **immediately**, not a second later.
3. Let the city decay and confirm a producer cell switches to the `+360 → +210` form.
4. Tab through the page and confirm each type row's button takes focus and Enter
   selects it.
5. Screenshot the sidebar.

- [ ] **Step 9: Run the whole gate**

Run: `mix check`
Expected: exit 0, coverage at or above 90%.

- [ ] **Step 10: Commit**

```bash
git add lib/armchair_metropolist_web/live/simulator_live.ex \
        test/armchair_metropolist_web/live/simulator_live_test.exs
git commit -m "feat(web): replace the Place row with a legend sidebar"
```

---

## Task 4: Collapse toggle and responsive verification

**Files:**
- Modify: `lib/armchair_metropolist_web/live/simulator_live.ex`
- Test: `test/armchair_metropolist_web/live/simulator_live_test.exs`

**Interfaces:**
- Consumes: `legend/1` from Task 3.
- Produces: assign `:sidebar_open` (boolean, default `true`) and event
  `"toggle_sidebar"`.

- [ ] **Step 1: Write the failing test**

Append inside the `describe "legend"` block:

```elixir
    test "the sidebar starts expanded and can be collapsed and reopened", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#legend-row-power_plant"), "must start expanded"

      view |> element("#toggle-sidebar") |> render_click()
      refute has_element?(view, "#legend-row-power_plant")

      view |> element("#toggle-sidebar") |> render_click()
      assert has_element?(view, "#legend-row-power_plant"), "reopening must restore it"
    end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/armchair_metropolist_web/live/simulator_live_test.exs`
Expected: FAIL — no element with id `toggle-sidebar`.

- [ ] **Step 3: Add the assign**

In `mount/3`, after the `:selected_type` assign:

```elixir
      |> assign(:sidebar_open, true)
```

- [ ] **Step 4: Add the event handler**

After the existing `handle_event("demolish", …)` clause:

```elixir
  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, :sidebar_open, not socket.assigns.sidebar_open)}
  end
```

- [ ] **Step 5: Wrap the legend in the toggle**

In `render/1`, replace the `<.legend … />` call with:

```heex
        <aside class="w-full min-[1450px]:w-auto">
          <button
            id="toggle-sidebar"
            type="button"
            class="btn btn-xs mb-2"
            phx-click="toggle_sidebar"
            aria-expanded={to_string(@sidebar_open)}
          >
            {if @sidebar_open, do: "Hide legend", else: "Show legend"}
          </button>

          <.legend
            :if={@sidebar_open}
            metrics={@metrics}
            node_types={@node_types}
            selected_type={@selected_type}
          />
        </aside>
```

The outermost element inside `legend/1` is already a plain `<div>`, so the `aside`
landmark is not nested — leave `legend/1` as written in Task 3.

- [ ] **Step 6: Run the test to verify it passes**

Run: `mix test test/armchair_metropolist_web/live/simulator_live_test.exs`
Expected: PASS.

- [ ] **Step 7: Mutation-verify the toggle**

Make the handler `{:noreply, socket}`.
Run the file again.
Expected: FAIL on "the sidebar starts expanded and can be collapsed and reopened".
Restore, confirm PASS.

- [ ] **Step 8: Verify responsive behaviour in a browser `[review]`**

The grid is a fixed 960px and cannot shrink, so the side-by-side layout must not engage
until both panes genuinely fit. Using the Browser tool's `resize_window`:

1. **1500px wide** — sidebar sits to the right of the grid, no horizontal page scroll.
2. **1440px wide** — still stacked (below the `min-[1450px]` threshold).
3. `tablet` (768px) — stacked; the legend table scrolls inside its own
   `overflow-x-auto` rather than widening the page.
4. `mobile` (375px) — stacked; confirm the page's horizontal scroll is caused by the
   grid alone and the sidebar adds none.
5. Screenshot at 1500px and at mobile.

If the sidebar overflows at 1500px, raise the `min-[…]` threshold to match what it
actually measures rather than letting the grid shrink.

- [ ] **Step 9: Run the whole gate**

Run: `mix check`
Expected: exit 0.

- [ ] **Step 10: Commit**

```bash
git add lib/armchair_metropolist_web/live/simulator_live.ex \
        test/armchair_metropolist_web/live/simulator_live_test.exs
git commit -m "feat(web): make the legend sidebar collapsible"
```

---

## Task 5: Update the playing guide `[review]`

**Files:**
- Modify: `docs/PLAYING.md`

**Interfaces:** none. Documentation only.

Two existing passages become false when Task 3 lands, and the generated-table test does
not check prose. **Replace them — appending is not enough.**

- [ ] **Step 1: Replace the stale Place-row reference**

In `## The controls`, replace:

```markdown
* **click an empty cell** — places the type currently selected in the *Place* row;
* **click a placed block** — demolishes it.
```

with:

```markdown
* **click a type in the legend** — selects it for placing;
* **click an empty cell** — places the currently selected type;
* **click a placed block** — demolishes it.
```

- [ ] **Step 2: Replace the stale metrics-panel reference**

Replace:

```markdown
So any shortfall reduces supply, which deepens the shortfall. The metrics panel shows
all four satisfaction figures; the lowest one is the only number that matters, because
each node takes the worst of the resources it consumes.
```

with:

```markdown
So any shortfall reduces supply, which deepens the shortfall. The totals row at the
foot of the legend shows all four satisfaction figures; the lowest one is the only
number that matters, because each node takes the worst of the resources it consumes.
```

- [ ] **Step 3: Describe the legend**

Add at the end of `## The controls`:

```markdown
The legend down the right-hand side lists every type with how many you have placed and
its net effect on each resource. Where a type produces a resource and its buildings are
damaged, the cell shows both figures — `+360 → +210` means 360 rated, 210 actually
supplied at current health. A dash means the type does not touch that resource at all,
which is different from netting to zero. The totals row gives city-wide supply, demand
and satisfaction, including the free baseline of 40 per resource.
```

- [ ] **Step 4: Confirm the generated tables are untouched**

Run: `mix test test/docs/playing_guide_test.exs`
Expected: PASS. The legend changes no rule, so a failure here means something else
moved — investigate rather than regenerating.

- [ ] **Step 5: Run the whole gate**

Run: `mix check`
Expected: exit 0.

- [ ] **Step 6: Commit**

```bash
git add docs/PLAYING.md
git commit -m "docs: describe the legend sidebar in the playing guide"
```

---

## Self-Review

**Spec coverage.** §2 layout and §2.1 matrix → Task 3; §2.2 totals row and the
satisfaction move → Task 3, with a test that the old list is gone; §2.3 selection →
Task 3, as a focusable button rather than a clickable row; §3 domain changes → Task 1;
§3.1 snapshot compatibility → nothing to do, it asserts an absence; §4 view changes →
Tasks 3 and 4; §5 testing → the test steps throughout; §6 risks → the browser steps in
Tasks 3 and 4. Task 2 has no spec section: it is a shipped bug the review surfaced,
which the feature depends on.

**Placeholder scan.** No TBD, TODO, "handle edge cases", or "similar to Task N".

**Type consistency.** `type_stats` keys (`count`, `rated_production`,
`actual_production`, `consumption`) defined in Task 1, used unchanged by `net_cell/2` in
Task 3. Element ids are consistent between the tests and the markup that produces them:
`legend-row-<type>`, `legend-totals`, `toggle-sidebar`, `metrics-tick`, and the
`data-cell="<type>-<resource>"` / `data-total="<resource>"` attributes.

**Review items and where each landed.**

| Finding | Resolution |
|---|---|
| P1 stale metrics after place/demolish | Task 2 — engine broadcasts the metrics it already computes |
| P1 duplicate-satisfaction assertion impossible | Task 3 Step 1 — distinct satisfaction per resource, scoped assertions |
| P2 vacuous em-dash assertion | Task 3 Step 1 — `element/2` on the cell, positive case first |
| P2 keyboard access | Task 3 Step 4 — a real `<button>` per row, `aria-pressed` |
| P2 breakpoint too early | Task 3 Step 3 — `min-[1450px]` and `shrink-0`, arithmetic shown |
| P2 daisyUI vs `AGENTS.md:35` | Global Constraints — conflict stated, decision recorded, override invited |
| P2 obsolete first-tick assumption | Tasks 2 and 3 — both stale moduledocs corrected |
| P2 guide only appended to | Task 5 — replaces both stale passages |
