# Money and labour: two new resources — design

**Date:** 2026-08-02
**Status:** approved, not yet implemented

## 1. Problem

Two node types have no reason to exist, and one city shape that should be impossible is not.

**`commercial` produces nothing.** It draws power 22, water 8, waste 14 and traffic 9 and returns
nothing to the city. Placing one is strictly worse than not placing one. `docs/PLAYING.md` says as
much — "Produce nothing at all: `commercial`, `residential`" — and its equilibrium analysis simply
omits both types.

**Nothing requires housing.** A city of pure industrial blocks runs indefinitely. In a real city
the industrial and commercial blocks are staffed by people who live somewhere.

Both are addressed by adding resources rather than special cases, because the engine already has
exactly the machinery required: supply, demand, satisfaction, and health decay driven by the worst
satisfaction among the resources a node consumes.

### Non-goals

* No build costs, and no placement-time refusal. The constraint is felt through decay, which is
  the failure mode the engine already models. See §5 for why that was preferred.
* No jobs requirement on residential. Real housing needs employment nearby; modelling the
  reverse direction as well is a separate mechanic and is not in scope.
* No labour requirement on `power_plant`, `water_plant`, `road_hub` or `park`. Staffing every type
  would make labour a near-universal tax and flatten the distinction being drawn.

## 2. The vocabulary

`Node.resources()` becomes:

```elixir
@resources [:power, :water, :waste, :traffic, :labour, :money]
```

Money is last because it is the odd one out — the only resource whose surplus survives the tick
boundary (§4). The order is a display decision the legend reads directly, so it is written out
rather than derived, exactly as today.

`node_test.exs:34` pins this list literally and must be updated with it. That test is doing its
job: the list is a published vocabulary, not an implementation detail.

## 3. Table changes

Additions only; every existing entry is untouched.

| type | produces | consumes |
|---|---|---|
| `commercial` | money 30.0 | labour 8.0 |
| `residential` | money 1.0, labour 4.0 | — |
| `industrial` | — | labour 12.0 |
| `water_plant` | — | money 5.0 |
| `road_hub` | — | money 4.0 |
| `park` | — | money 3.0 |

Baseline capacity gains both, explicitly zero:

```elixir
@baseline_capacity %{power: 40.0, water: 40.0, waste: 40.0, traffic: 40.0,
                     labour: 0.0, money: 0.0}
```

`simulation_calculator_test.exs:54` asserts `Map.keys(baseline_capacity()) == Node.resources()`, so
omitting either key fails the gate. The zeros are load-bearing, not filler: **no free workers** is
the whole labour mechanic, and **no free income** is what forces commercial to be built.

Both new figures ride the existing production table, so they scale with producer health for free —
a decaying residential block houses fewer workers and pays less tax, with no extra code.

## 4. Money is a treasury

Money is the first resource whose unspent supply carries over. Every other resource discards its
surplus at the tick boundary.

`CityMap` gains one field:

```elixir
defstruct width: 40, height: 30, tick: 0, nodes: %{}, money: 500.0
```

500.0 is the opening grant: roughly 50 ticks (50 seconds, at the configured 1000ms interval) of
runway for a city drawing the ~10/tick net deficit that §7 derives. Long enough to establish
housing and reach commercial, short enough that ignoring money is not an option.

Which resources carry over is one named list in `SimulationCalculator`, not a test against the
atom `:money` at each site:

```elixir
@carryover [:money]
```

### The rule

```
supplied(r)      = baseline(r) + Σ health-scaled production        # unchanged
carried(r)       = city_map.money when r in @carryover, else 0.0   # new
demanded(r)      = Σ full consumption                              # unchanged
satisfaction(r)  = min(1.0, (supplied + carried) / demanded)       # + carried
deficit(r)       = max(0.0, demanded - (supplied + carried))       # + carried
money'           = max(0.0, supplied(:money) + carried(:money) - demanded(:money))
```

`advance_tick/1` writes the new balance into the map it returns, alongside the incremented tick:
`%{city_map | nodes: nodes, tick: tick + 1, money: money'}`. It is computed from the **pre-tick**
stats like everything else in a tick, so all nodes see one consistent set of city-wide conditions
regardless of map iteration order — the property the calculator's moduledoc already promises.

`SimulationMetrics` gains a `money: float()` field, populated from the city map in `build/2`. The
LiveView receives metrics, never the city map, so without this the balance cannot reach the
treasury line in §6.

`carried` is `0.0` for every existing resource, so `supplied + carried` reduces to today's
behaviour and no existing call site changes meaning. The balance floors at zero: debt is not
modelled, and an unpayable upkeep expresses itself as satisfaction below 1.0, which the existing
decay path already handles.

`resource_stats` therefore gains a field:

```elixir
@type resource_stats :: %{
        supplied: float(),           # production this tick — flow only
        carried: float(),            # surplus carried in; 0.0 for every flow resource
        demanded: float(),
        deficit: float(),            # over supplied + carried
        satisfaction: float(),       # over supplied + carried — drives health decay,
                                      # the deficit notification and the Tightest line
        flow_satisfaction: float()   # over supplied alone — drives the totals cell
      }
```

**Why a separate field rather than folding the balance into `supplied`.** The legend renders
`supplied/demanded · met`. With the balance inside `supplied`, a solvent city reads `513/23 ·
100%` — the ratio dominated by savings, and the per-tick economy invisible.

**Amended by the whole-branch review (2026-08-02).** The first cut of this design left the totals
cell rendering `satisfaction` — the balance-inclusive figure — unchanged, reasoning that a
separate `carried` field made the invariant "explicit enough" without touching the cell itself. It
did not: with the balance left out of the *display* but still folded into the *satisfaction* the
engine computed, the cell read `13/23 · 100%` — dividing the two numbers shown gives 57%, not the
100% printed beside them, and nothing on screen explained the gap. That is a cell contradicting
itself, not an invariant made explicit; a fresh city with one park read `0/3 · 100.0%`.

The fix adds `flow_satisfaction`: the same `min(1.0, · / ·)` computation as `satisfaction`, with
the same `demanded == 0.0 -> 1.0` clause, but over `supplied` alone — `carried` never enters it.
`totals_cell/2` now renders `flow_satisfaction`, so its percentage is always derivable from the two
numbers beside it. `satisfaction` is untouched and stays balance-inclusive, because its other three
consumers — `worst_satisfaction/2` (health decay), the deficit notification, and
`tightest_resource/1` — all answer "what is damaging the city right now", and a deficit the
treasury is covering must not decay anything or page anyone. The totals cell answers a different
question, "is my per-tick economy balanced", and now has a field computed on that basis alone. For
every flow resource `carried` is `0.0`, so `flow_satisfaction == satisfaction` and nothing visibly
changes there; the two figures diverge only for money, and only while savings are covering a
shortfall.

### Old snapshots

Every stored city predates this field. Measured: a `CityMap` term encoded without `money` decodes
under `:safe` as a struct carrying only the old keys, and `city_map.money` then raises `KeyError`.
That is not a clean failure — it happens after a successful load, inside the engine, so it
crash-loops the supervised process rather than falling back to a new city.

Hydration normalises before use:

```elixir
Map.merge(%CityMap{}, Map.delete(decoded, :__struct__))
```

Verified to fill the default while preserving the stored `tick` and `nodes`.

`SnapshotVocabulary` needs no change: `money` is a float, so it introduces no new atom, and no new
struct becomes reachable from `CityMap`. Its warning covers atom-valued fields specifically, and
this is not one.

## 5. Labour is an ordinary resource

Residential produces it; industrial and commercial consume it. With no housing, supply is the
baseline zero, satisfaction is 0.0, and both types decay at the full `6.0/tick` — dead in about 17
ticks.

**Why not a placement rule.** `ManageInfrastructure.place/4` could refuse industrial or commercial
without sufficient housing, and that was considered. Three reasons against:

1. It only checks at placement. Demolishing housing afterwards leaves the city in exactly the
   state the rule forbids, so as a *constraint* it is strictly weaker than the resource.
2. `SimulatorLive` currently discards placement errors — `{:error, _reason} -> {:noreply, socket}`
   — so a refusal would be a click that silently does nothing until error feedback is built too.
3. The resource version explains itself. A labour column in the legend shows who needs workers and
   how badly, where a rejected click communicates nothing.

A simulator should let the player make the mistake and then show them the consequence.

## 6. Presentation

**The legend** gains two resource columns from the existing `Node.resources()` loop; no template
change is needed for them to appear. The per-block and city-total cells work unchanged: every new
figure is a whole number, so `signed/1`'s `round/1` stays truthful and the `rated → actual`
divergence comparison keeps its current form. (An earlier draft used 2.1 for residential money,
which would have rendered `+2` against a city total of `+21` for ten blocks. Whole numbers avoid
introducing a second precision rule and the divergence-arrow bug that comes with it.)

**Metrics** gains a treasury line showing `city_map.money`. A stock has no place in a totals row
built for supply, demand and satisfaction, and the balance is what tells the player how long the
current deficit is survivable.

**`tightest_resource`** picks both up with no change, so "Tightest: labour 0%" appears the moment
industry outgrows its housing.

**The deficit notification** filters on `satisfaction < 1.0` across all resources
(`city_engine.ex:283`) and so includes both automatically. For money this fires only once the
balance is exhausted, which is the correct moment — not while savings are covering the gap.

**Wrap thresholds must be re-measured.** Four resource columns become six, widening the matrix and
moving both windows. `render/1` currently carries 1900 and 1287, chosen as midpoints of measured
windows `[1813, 1988]` and `[1215, 1358]`. Re-derive by the procedure recorded there: binary-search
a clone of the row for the viewport at which the sidebar stops wrapping, once with the children
stacked (`W_col`) and once with them in a row (`W_row`), then take the midpoint of `[W_col, W_row]`.
**Do not compute the new values from the old ones plus an estimated column width** — the last
attempt to reason about this matrix arithmetically was wrong every time, because a `width: 100%`
table reports its container. Measure, and verify at the boundary pixel.

The sidebar may end up permanently below the grid at ordinary window sizes. That is an accepted
outcome, not a regression: the layout is content-driven precisely so it can make that call.

## 7. Balance

At the ratio `docs/PLAYING.md` documents — roughly 3 power, 3 water, 2 industrial, 2 road hubs per
13 residential:

| | supply | demand | net |
|---|---|---|---|
| labour | 13 × 4 = **52** | 2 industrial × 12 = **24** | +28 |
| money | 13 × 1 = **13** | 3 × 5 + 2 × 4 = **23** | **−10** |

So labour has headroom for roughly two more industrial blocks, and money runs a deficit that
drains the 500 grant in about 50 ticks. One commercial block flips money to +10/tick while
consuming 8 labour, leaving 20 spare. Both constraints bind without either being trivial, and
commercial becomes the thing you build to keep growing.

The second-order effect is the point: commercial draws power, water, waste and traffic, so funding
the city grows the infrastructure that costs money to run.

## 8. Accepted consequences

* **The death spiral tightens.** Residential feeds industrial (labour) and industrial feeds
  residential (waste capacity). Losing housing now withers industry, which removes waste capacity,
  which hurts the surviving housing. Dramatic and realistic, but it makes collapse faster and
  recovery harder.
* **`docs/PLAYING.md` needs rework, not edits.** Its production and consumption tables gain
  columns; "Produce nothing at all: `commercial`, `residential`" becomes false for both; the
  equilibrium ratio and the recovery table are both computed against the old coupling and must be
  recomputed against the new one.
* **`park` gets worse.** The guide already calls it "usually a trap"; a money cost with no labour
  or production offset deepens that. Left as is — a type that is situationally bad is a legitimate
  design, and rebalancing parks is not what this change is for.

## 9. Testing

Domain behaviour is unit-testable and should be; presentation is verified in a browser.

* **The vocabulary.** `Node.resources()` equals the six-element list, and every one has a
  `baseline_capacity` key. The second assertion already exists and needs no change — it will fail
  on its own if a baseline entry is forgotten.
* **Carry-over.** A city with surplus money accumulates it across a tick; one with a deficit draws
  the balance down; a balance at zero with unpayable upkeep yields `satisfaction < 1.0` rather than
  a negative balance. Each mutation-verified separately.
* **`carried` is zero for flows.** Assert it for a non-money resource, so folding the balance into
  `supplied` later cannot pass silently.
* **Labour starves the unhoused.** A city of one industrial block and no residential loses health
  at the full decay rate; adding sufficient residential stops it. This is the requirement, so it
  gets a direct test rather than being inferred from the tables.
* **Old snapshots hydrate.** A `CityMap` term encoded without `money` loads to a city with the
  default balance and its stored `tick` and `nodes` intact. Without this the failure is a
  crash-loop, and the existing suite would not catch it — nothing else constructs a `CityMap` from
  a term missing a field.
* **Presentation** — the two new columns, the treasury line, and the re-measured thresholds — is
  verified in the browser at the boundary pixels, in both collapse states, as recorded in §6.
