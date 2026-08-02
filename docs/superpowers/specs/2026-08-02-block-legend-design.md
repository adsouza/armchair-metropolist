# Block legend — design

**Date:** 2026-08-02
**Status:** implemented — see `docs/superpowers/plans/2026-08-02-block-legend.md`

## 1. Purpose

Nothing in the UI says what a block does. A player picks `industrial` from a row of
seven identical buttons with no indication that it supplies 90 waste capacity and
draws 40 power, and the first sign of a mistake is a city dying several minutes later.
`docs/PLAYING.md` now explains the rules, but a document you have to go and read is a
poor substitute for the numbers being on screen while you play.

This adds a legend that answers three questions at the point of use:

1. what does each block type do to each resource;
2. how many of each are on the grid;
3. what they add up to, against the demand they create.

### Non-goals

* No change to any simulation rule. This is presentation over existing state.
* No spatial or adjacency mechanic. Layout remains free (see `docs/PLAYING.md`).
* No historical charting. The legend shows the current tick only.

## 2. Layout

The page becomes two columns: the grid on the left, a sidebar down the right edge.

```
┌────────────────────────────┬──────────────────────────────────────────┐
│                            │  Types                          [ ⌄ ]    │
│                            │  ┌────────────┬──────┬──────┬─────┬────┐ │
│                            │  │ type       │power │water │waste│traf│ │
│         city grid          │  │ power_pl ×3│+360  │ −60  │ −36 │ −9 │ │
│                            │  │            │→ +210│      │     │    │ │
│                            │  │ …                                    │ │
│                            │  ├────────────┼──────┼──────┼─────┼────┤ │
│                            │  │ TOTAL      │ …    │ …    │ …   │ …  │ │
│                            │  └────────────┴──────┴──────┴─────┴────┘ │
│                            │                                          │
│                            │  Metrics                                 │
│                            │  Tick / Nodes / Avg health / Offline     │
└────────────────────────────┴──────────────────────────────────────────┘
```

* The sidebar replaces the current **Place** button row and the current **Metrics**
  block, both of which sit above the grid today. Neither survives in its old position.
* The sidebar is **collapsible and starts expanded**. Collapsed, it leaves a labelled
  toggle so it can be brought back.
* Below the `lg` breakpoint the sidebar stacks underneath the grid rather than
  squeezing it: the grid is a fixed 40×30 cells at 24px — measured at 960px in the
  browser — and has no ability to shrink.

### 2.1 The matrix

One row per node type, in a fixed four-column resource matrix — the same four columns
on every row, including where a type does not touch a resource.

Fixed columns rather than per-row chips because the question a player actually has is
"water is at 71%, who is drinking it?", and only aligned columns let you read one
resource down all seven types. Chips would be narrower and unscannable.

Each cell shows the type's **net** effect on that resource: production minus
consumption, multiplied by the number placed.

Where a type produces the resource, the cell shows **rated and current**:

```
+360 → +210
```

Rated is `count × base production`. Current is the health-scaled figure the simulation
is actually using this tick. Cells that involve no production show a single number,
because consumption never scales with health.

Showing both is the point rather than decoration: production scales with health and
consumption does not, so the two figures diverge precisely when a city is collapsing.
A player watching supply fall while demand holds steady can see the death spiral
happening instead of inferring it.

Empty cells render as `—`, not `0`, so "does not interact" reads differently from "nets
to zero".

No node type currently both produces and consumes the same resource, so today every
cell is purely one or the other. The cell is still defined as
`production − consumption` so that a future type doing both needs no new rule.

### 2.2 The totals row

A final row sums every type, in the same four columns.

It deliberately shows something different from the rows above it: **supply, demand and
satisfaction**, not a single net figure. A net city total would be the wrong summary —
satisfaction is `supply ÷ demand`, so `+20 net` means something entirely different at
`60/40` than at `220/200`, and it is satisfaction that decides whether the city lives.
The rows answer "what does this type do for me"; the totals answer "am I short".

Supply here includes the free baseline capacity of 40 per resource, which belongs to no
type and therefore appears in no row. The totals column will consequently exceed the
sum of the rows above it by exactly that baseline, and the row is labelled to say so —
otherwise the arithmetic looks broken.

Per-resource satisfaction currently lives in the Metrics block. It **moves here** —
leaving it in both places would put the same figure on screen twice. The Metrics block
keeps tick, node count, average health and offline count, and sits directly below the
matrix in the sidebar.

### 2.3 Selection

Each type row is the selection control, replacing the button row. Clicking anywhere on
a row selects that type for placing; the selected row carries the existing
`btn-primary` treatment. Rows keep `cursor-pointer` and a title naming the action, for
the same reason the grid squares do.

## 3. Domain changes

`SimulationMetrics` gains a `by_type` breakdown:

```elixir
@type type_stats :: %{
        count: non_neg_integer(),
        rated_production: %{Node.resource() => float()},
        actual_production: %{Node.resource() => float()},
        consumption: %{Node.resource() => float()}
      }

@type t :: %__MODULE__{
        # …existing fields…
        by_type: %{Node.node_type() => type_stats()}
      }
```

Built in `SimulationMetrics.build/2`, beside the existing `avg_health` and
`offline_count` aggregation, from the nodes it already walks.

The aggregation belongs in the Domain rather than the view. It is simulation
arithmetic — the same rated-versus-actual distinction the calculator itself turns on —
and the view is the one place in this codebase with no test coverage worth the name.
The boundary graph would permit `ArmchairMetropolistWeb` to call `Node.production/1`
directly, since `Domain` exports `Entities.Node`; doing so would put the rules in
markup instead.

`by_type` includes **every** node type, with `count: 0` and zeroed maps for types not
present, so the legend renders a stable seven rows and does not reflow as a city grows.

No change to `SimulationCalculator`, to the tick, to the delta, or to any port. The
metrics already ride the existing `{:city_metrics, metrics}` broadcast the LiveView
subscribes to, so nothing new is plumbed.

### 3.1 Snapshot compatibility

`SimulationMetrics` is **not** persisted — snapshots store `CityMap` only — so adding a
field cannot invalidate an existing snapshot. Worth stating because
`SnapshotVocabulary` exists precisely to guard atom-valued fields that *are* persisted,
and this change deliberately does not touch it.

## 4. View changes

`SimulatorLive` renders the sidebar from `@metrics.by_type` and `@metrics.resources`.
No new assigns beyond a boolean for the collapsed state, and no new events beyond a
toggle; `select_type` already exists and keeps its contract.

The template grows enough that the sidebar should be its own function component in the
same module, keeping `render/1` readable.

## 5. Testing

**`SimulationMetrics.build/2`** — unit tests for `by_type`:

* counts per type, including zero for absent types;
* rated production is `count × base`, independent of health;
* actual production is health-scaled, and **diverges from rated** when health is below
  100 — the case that carries the logic;
* consumption is `count × base` and does **not** scale with health;
* an empty city yields every type at zero rather than an empty map.

**`SimulatorLive`** — the legend shows a count that changes after placing, and the
totals row reflects it. Assert on content, not on markup punctuation: the existing
tooltip test had to be loosened once already for pinning presentation.

Both mutation-verified before being trusted, per `TESTING.md`.

## 6. Risks

* **Sidebar width.** Four resource columns with two numbers in some cells is wide. If
  it crowds the grid at common window sizes, the fallback is abbreviating the rated
  figure rather than dropping columns — the columns are the feature.
* **Stacking below `lg`.** Untested territory for this app, which has only ever been a
  single centred column. Needs checking at mobile and tablet widths in a browser, not
  assumed.
