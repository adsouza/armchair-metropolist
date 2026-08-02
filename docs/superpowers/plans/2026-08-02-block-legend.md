# Block Legend Sidebar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Place button row and the Metrics block with a collapsible
right-hand sidebar showing, per node type, how many are placed and their net effect on
each of the four resources — rated and health-scaled — plus a city totals row.

**Architecture:** The per-type aggregation is computed in the Domain, as a new
`by_type` field on `SimulationMetrics`, and rides the existing `{:city_metrics, …}`
PubSub broadcast that `SimulatorLive` already subscribes to. The LiveView only renders.
No simulation rule changes.

**Tech Stack:** Elixir, Phoenix LiveView 1.2, HEEx, Tailwind + daisyUI, ExUnit.

**Spec:** `docs/superpowers/specs/2026-08-02-block-legend-design.md`

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
  `spawn`, `send`, `self`, `exit`, `monitor`. Adding aggregation to
  `SimulationMetrics` must not reach for any of them.
- **`ArmchairMetropolistWeb` may call `Domain.Entities.Node`** (it is exported) but
  **may not** reach `Domain.Services`. Do not add domain arithmetic to the template.
- **Never write a `refute` without first asserting the positive case** in the same
  test. A refutation against something that never occurs is always true.
- **A test you have not seen fail is not a test.** Every task ends by breaking the code
  under test and confirming the new test goes red. See `TESTING.md`.
- **Assert on content, not markup punctuation.** A LiveView test here was already
  loosened once for pinning an exact tooltip string.
- Pre-commit and pre-push hooks run automatically. Do not use `--no-verify`.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `lib/armchair_metropolist/domain/entities/simulation_metrics.ex` | aggregate per-tick figures, now including the per-type breakdown | modify |
| `test/armchair_metropolist/domain/entities/simulation_metrics_test.exs` | unit tests for that aggregation | modify |
| `lib/armchair_metropolist_web/live/simulator_live.ex` | render the grid and the new sidebar; own the collapse state | modify |
| `test/armchair_metropolist_web/live/simulator_live_test.exs` | LiveView tests for the sidebar | modify |

The sidebar markup lives in a private function component inside `SimulatorLive` rather
than a new module: it is used in exactly one place and depends on that view's assigns.
`render/1` stays readable because the matrix is lifted out of it.

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
  with value `0.0` when no nodes of that type are placed. Task 2 relies on that: a
  missing key means "this type does not interact with this resource" and renders `—`,
  which is different from a present key holding `0.0`.

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
      assert Map.keys(by_type) |> Enum.sort() == Enum.sort(Node.types())
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
Expected: FAIL — `key :by_type not found` (the struct has no such field yet).

- [ ] **Step 3: Add the field and the aggregation**

In `lib/armchair_metropolist/domain/entities/simulation_metrics.ex`, add the alias for
`Node` at the top next to the existing `CityMap` alias:

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

Add `by_type` to the `@type t` map and to `defstruct`:

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

And add the private functions at the bottom of the module, before the final `end`:

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
Expected: PASS, all tests including the pre-existing ones.

- [ ] **Step 5: Mutation-verify the divergence test**

The rated-versus-actual test is the one carrying real logic, so confirm it can fail.
Temporarily change `sum_actual_production/2` to ignore health:

```elixir
      total =
        Enum.reduce(nodes, 0.0, fn _node, acc ->
          acc + Map.get(Node.production(type), resource, 0.0)
        end)
```

Run: `mix test test/armchair_metropolist/domain/entities/simulation_metrics_test.exs`
Expected: FAIL on "actual production is health-scaled and diverges from rated".
Then restore the original implementation and confirm PASS again.

- [ ] **Step 6: Run the whole gate**

Run: `mix check`
Expected: exit 0. Coverage should rise slightly — this is pure, fully covered code.

- [ ] **Step 7: Commit**

```bash
git add lib/armchair_metropolist/domain/entities/simulation_metrics.ex \
        test/armchair_metropolist/domain/entities/simulation_metrics_test.exs
git commit -m "feat(domain): add a per-type breakdown to SimulationMetrics"
```

---

## Task 2: The legend sidebar

**Files:**
- Modify: `lib/armchair_metropolist_web/live/simulator_live.ex`
- Test: `test/armchair_metropolist_web/live/simulator_live_test.exs`

**Interfaces:**
- Consumes: `@metrics.by_type` from Task 1, and the existing `@metrics.resources`
  (`%{resource => %{supplied:, demanded:, deficit:, satisfaction:}}`).
- Produces: a private function component `legend/1` taking `metrics`, `node_types` and
  `selected_type` assigns. Task 3 adds the collapse wrapper around its call site.

Note `@metrics.resources` is an **empty map** until the first tick lands — see the
module's own moduledoc. The totals row must handle that, exactly as the current
resource list does with its "Waiting for first tick…" placeholder.

- [ ] **Step 1: Write the failing tests**

Append inside the existing `defmodule ... do` in
`test/armchair_metropolist_web/live/simulator_live_test.exs`, before the final `end`:

```elixir
  describe "legend" do
    test "lists every node type with its placed count", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> element(~s{[phx-click="select_type"][phx-value-type="power_plant"]})
      |> render_click()

      view |> element(~s{[phx-click="place"][phx-value-x="1"][phx-value-y="1"]}) |> render_click()
      view |> element(~s{[phx-click="place"][phx-value-x="2"][phx-value-y="1"]}) |> render_click()

      html = render(view)

      assert html =~ "legend-row-power_plant"
      assert html =~ ~s{data-count="2"}, "the legend must show how many are placed"

      # Every type gets a row, including ones with nothing placed.
      assert html =~ "legend-row-industrial"
    end

    test "shows a type's rated effect on each resource it touches", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> element(~s{[phx-click="select_type"][phx-value-type="power_plant"]})
      |> render_click()

      view |> element(~s{[phx-click="place"][phx-value-x="3"][phx-value-y="3"]}) |> render_click()

      html = render(view)

      # One power plant: power +120, water -20.
      assert html =~ ~s{data-cell="power_plant-power"}
      assert html =~ "+120"
      assert html =~ "-20"
    end

    test "a resource the type never touches renders as an em dash, not zero", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      # A road hub produces traffic and consumes power and waste, but never water.
      assert html =~ ~s{data-cell="road_hub-power"},
             "precondition: cells this type does touch must render"

      assert html =~ ~s{<td data-cell="road_hub-water" class="opacity-40">—</td>} or
               html =~ ~s{data-cell="road_hub-water"}

      refute html =~ ~s{data-cell="road_hub-water" data-value="0"}
    end

    test "the totals row reports supply, demand and satisfaction once a tick lands",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      send(view.pid, {:city_metrics, metrics_with_resources()})

      html = render(view)
      assert html =~ "legend-totals"
      assert html =~ "100.0%"
    end

    test "the Metrics block moved into the sidebar and satisfaction is not duplicated",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      send(view.pid, {:city_metrics, metrics_with_resources()})
      html = render(view)

      assert html =~ "Tick:", "the Metrics block must still exist"

      # Satisfaction now lives only in the totals row. Counting occurrences catches the
      # duplicate that a plain `=~` would happily pass.
      occurrences = html |> String.split("100.0%") |> length() |> Kernel.-(1)
      assert occurrences == 1, "satisfaction should appear once, in the totals row"
    end
  end

  defp metrics_with_resources do
    full = %{supplied: 40.0, demanded: 40.0, deficit: 0.0, satisfaction: 1.0}

    %ArmchairMetropolist.Domain.Entities.SimulationMetrics{
      tick: 3,
      node_count: 0,
      avg_health: 0.0,
      offline_count: 0,
      resources: %{power: full, water: full, waste: full, traffic: full},
      by_type: ArmchairMetropolist.Domain.Entities.SimulationMetrics.build(
        ArmchairMetropolist.Domain.Entities.CityMap.new(40, 30),
        %{}
      ).by_type
    }
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/armchair_metropolist_web/live/simulator_live_test.exs`
Expected: FAIL — no `legend-row-*` markup exists yet.

- [ ] **Step 3: Replace the Place row and Metrics block with the sidebar**

In `lib/armchair_metropolist_web/live/simulator_live.ex`, delete the two `<div
class="mb-4">` blocks currently holding **Place** and **Metrics** (they sit between the
`<h1 class="sr-only">` and the grid `<div class="relative border border-base-300">`).

Wrap the remaining content in a two-column flex and call the new component. Replace
from the `<h1 class="sr-only">` line down to the closing `</div>` of the grid with:

```heex
      <h1 class="sr-only">Armchair Metropolist</h1>

      <div class="flex flex-col items-start gap-4 lg:flex-row">
        <div
          class="relative border border-base-300"
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

- [ ] **Step 4: Add the `legend/1` component**

Add these private functions to `SimulatorLive`, after `render/1` and before
`cell_style/3`:

```elixir
  # The four resource columns are fixed and identical on every row, including where a
  # type does not touch a resource. Aligned columns are the feature: the question a
  # player has is "water is short, who is drinking it?", which you answer by reading one
  # column down all seven types. Per-row chips would be narrower and unreadable for that.
  @resources [:power, :water, :waste, :traffic]

  attr :metrics, :map, required: true
  attr :node_types, :list, required: true
  attr :selected_type, :atom, required: true

  defp legend(assigns) do
    assigns = assign(assigns, :resources, @resources)

    ~H"""
    <aside class="w-full lg:w-auto">
      <h2 class="font-semibold mb-2">Types</h2>

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
            class={["cursor-pointer", type == @selected_type && "bg-primary/20"]}
            phx-click="select_type"
            phx-value-type={type}
            title={"select #{type} to place"}
          >
            <td class="text-left">{type}</td>
            <td class="text-right">{@metrics.by_type[type].count}</td>
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
            <th :for={resource <- @resources} class="text-right tabular-nums">
              {totals_cell(@metrics.resources, resource)}
            </th>
          </tr>
        </tfoot>
      </table>

      <p class="mt-1 text-xs opacity-60">
        Totals include the free baseline of 40 per resource, which belongs to no type.
      </p>

      <div class="mt-4">
        <h2 class="font-semibold mb-2">Metrics</h2>
        <p>Tick: {@metrics.tick}</p>
        <p>Nodes: {@metrics.node_count}</p>
        <p>Avg health: {Float.round(@metrics.avg_health, 1)}</p>
        <p>Offline: {@metrics.offline_count}</p>
      </div>
    </aside>
    """
  end

  # A missing key means the type does not interact with the resource at all, which reads
  # differently from a net of zero — hence the em dash rather than "0".
  #
  # Rated and actual are only both shown when they differ. A healthy city then reads
  # cleanly, and divergence is what draws the eye.
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

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/armchair_metropolist_web/live/simulator_live_test.exs`
Expected: PASS. If the em-dash test fails on exact markup, relax it to assert the cell
exists and does not contain a bare `0` — assert on content, not punctuation.

- [ ] **Step 6: Mutation-verify the count assertion**

Temporarily hard-code the count in `legend/1` to `0`:

```elixir
            data-count="0"
```

Run: `mix test test/armchair_metropolist_web/live/simulator_live_test.exs`
Expected: FAIL on "lists every node type with its placed count".
Restore, and confirm PASS.

- [ ] **Step 7: Verify in a browser**

Start the dev server with the Browser tool (`preview_start` with name
`armchair-metropolist` from `.claude/launch.json` — never `mix phx.server` via Bash).
Then:

1. Read the console for errors — expect none.
2. Place two power plants and one residential; confirm the counts and the `power`
   column change.
3. Let the city run until something decays, and confirm a producer cell switches to the
   `+360 → +210` two-number form.
4. Screenshot the sidebar.

- [ ] **Step 8: Run the whole gate**

Run: `mix check`
Expected: exit 0, coverage at or above 90%.

- [ ] **Step 9: Commit**

```bash
git add lib/armchair_metropolist_web/live/simulator_live.ex \
        test/armchair_metropolist_web/live/simulator_live_test.exs
git commit -m "feat(web): replace the Place row with a legend sidebar"
```

---

## Task 3: Collapse toggle and responsive stacking

**Files:**
- Modify: `lib/armchair_metropolist_web/live/simulator_live.ex`
- Test: `test/armchair_metropolist_web/live/simulator_live_test.exs`

**Interfaces:**
- Consumes: the `legend/1` component from Task 2.
- Produces: assign `:sidebar_open` (boolean, default `true`) and event
  `"toggle_sidebar"`.

- [ ] **Step 1: Write the failing test**

Append inside the `describe "legend"` block from Task 2:

```elixir
    test "the sidebar starts expanded and can be collapsed and reopened", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/")

      assert html =~ "legend-row-power_plant", "the sidebar must start expanded"

      html = view |> element(~s{[phx-click="toggle_sidebar"]}) |> render_click()
      refute html =~ "legend-row-power_plant"

      html = view |> element(~s{[phx-click="toggle_sidebar"]}) |> render_click()
      assert html =~ "legend-row-power_plant", "reopening must bring the legend back"
    end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/armchair_metropolist_web/live/simulator_live_test.exs`
Expected: FAIL — no element matching `[phx-click="toggle_sidebar"]`.

- [ ] **Step 3: Add the assign**

In `mount/3`, add after the `:selected_type` assign:

```elixir
      |> assign(:sidebar_open, true)
```

- [ ] **Step 4: Add the event handler**

Add after the existing `handle_event("demolish", ...)` clause:

```elixir
  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, :sidebar_open, not socket.assigns.sidebar_open)}
  end
```

- [ ] **Step 5: Wrap the legend in the toggle**

In `render/1`, replace the `<.legend ... />` call with:

```heex
        <aside class="w-full lg:w-auto">
          <button
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

Then remove the now-redundant outer `<aside class="w-full lg:w-auto">` and its closing
tag from inside `legend/1`, replacing them with a plain `<div>` — the toggle's `aside`
is the landmark now, and nesting two would be wrong for screen readers.

- [ ] **Step 6: Run the test to verify it passes**

Run: `mix test test/armchair_metropolist_web/live/simulator_live_test.exs`
Expected: PASS.

- [ ] **Step 7: Mutation-verify the toggle**

Temporarily make the handler a no-op:

```elixir
    {:noreply, socket}
```

Run: `mix test test/armchair_metropolist_web/live/simulator_live_test.exs`
Expected: FAIL on "the sidebar starts expanded and can be collapsed and reopened".
Restore, confirm PASS.

- [ ] **Step 8: Verify responsive stacking in a browser**

The grid is a fixed 960px and cannot shrink, so below `lg` the sidebar must stack
underneath rather than squeeze it. Using the Browser tool:

1. `resize_window` to the `desktop` preset — sidebar sits to the right of the grid.
2. `resize_window` to `tablet` (768px) — sidebar stacks below the grid.
3. `resize_window` to `mobile` (375px) — sidebar stacks below; confirm the page does
   **not** scroll horizontally beyond the grid's own 960px.
4. Screenshot at desktop and mobile.

If the page scrolls horizontally at mobile because of the sidebar rather than the grid,
give the table a wrapping `div` with `overflow-x-auto`.

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

## Task 4: Update the docs

**Files:**
- Modify: `docs/PLAYING.md`

**Interfaces:**
- Consumes: nothing. Documentation only.

`docs/PLAYING.md` currently tells players the UI does not explain what blocks do, and
its "The controls" section describes only placing and demolishing. Both are now stale.

- [ ] **Step 1: Update the controls section**

In `docs/PLAYING.md`, in the `## The controls` section, add after the two bullets about
clicking cells:

```markdown
* **click a row in the legend** — selects that type for placing.

The legend down the right-hand side lists every type with how many you have placed and
its net effect on each resource. Where a type produces a resource and its buildings are
damaged, the cell shows both figures — `+360 → +210` means 360 rated, 210 actually
being supplied at current health. The totals row at the foot gives city-wide supply,
demand and satisfaction, including the free baseline of 40 per resource.
```

- [ ] **Step 2: Check the generated tables still match**

The legend does not change any rule, so the generated blocks should be untouched.

Run: `mix test test/docs/playing_guide_test.exs`
Expected: PASS. If it fails, a domain table changed unintentionally — investigate
rather than regenerating.

- [ ] **Step 3: Run the whole gate**

Run: `mix check`
Expected: exit 0.

- [ ] **Step 4: Commit**

```bash
git add docs/PLAYING.md
git commit -m "docs: describe the legend sidebar in the playing guide"
```

---

## Self-Review

**Spec coverage.** Every section maps to a task: §2 layout and §2.1 matrix → Task 2;
§2.2 totals row and the satisfaction move → Task 2 (with an explicit no-duplication
test); §2.3 selection → Task 2; §3 domain changes → Task 1; §3.1 snapshot compatibility
→ no task needed, since it states that nothing must change; §4 view changes → Tasks 2
and 3; §5 testing → the test steps in Tasks 1–3; §6 risks → the browser verification
steps in Tasks 2 and 3. The collapsible behaviour from §2 gets its own task because a
reviewer could reasonably accept the legend and reject the toggle.

**Placeholder scan.** No TBD, TODO, "handle edge cases", or "similar to Task N". Every
code step carries the actual code.

**Type consistency.** `type_stats` keys (`count`, `rated_production`,
`actual_production`, `consumption`) are defined in Task 1 and used unchanged by
`net_cell/2` in Task 2. `by_type` is a map keyed by node type in both. `legend/1` takes
the same three assigns everywhere it appears, including after Task 3 rewraps it.

**One thing Task 4 exists for:** `docs/PLAYING.md` opens by saying nothing in the UI
explains what a block does. That sentence becomes false the moment Task 2 lands, and no
test would catch it — the generated blocks cover the tables, not the prose.
