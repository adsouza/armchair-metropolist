# Playing Armchair Metropolist

The simulation is unforgiving in a specific way, and knowing that way is most of the
game. This guide's reference tables and capacity figures are generated from the domain
code and checked by `test/docs/playing_guide_test.exs`, so they cannot drift away from
the rules — see [TESTING.md](../TESTING.md).

## The controls

There are three things to click, and the last two are the same gesture on the same
square — worth knowing, because nothing on screen separates them:

* **click a type in the legend** — selects it for placing;
* **click an empty cell** — places the currently selected type;
* **click a placed block** — demolishes it.

Hover either grid square and the tooltip names the action it will perform. Demolishing
matters more than it looks: it is the only way to reduce demand, and therefore the only
way out of a collapse.

The legend — to the right of the grid on a wide enough window, stacked below it
otherwise — lists every type with how many you have placed and its net effect on each
resource. Where a type produces a resource and its buildings are damaged, the cell shows
both figures — `+360 → +210` means 360 rated, 210 actually supplied at current health. A
dash means the type does not touch that resource at all, which is different from
netting to zero. The totals row gives city-wide supply, demand and satisfaction,
including the free baseline of 40 per resource.

**Show detail / Hide detail** collapses the legend to its type and count columns, which
is how you make the window narrower — the four resource columns are most of its width.
Collapsing never takes away the type list, so you can still choose what to place, and it
never hides the metrics. The satisfaction figures go with the resource columns, so while
collapsed the metrics carry a *Tightest* line naming the resource in shortest supply.

### Position does not matter

**Blocks do not need to be adjacent, or anywhere near each other.** Resources are
pooled across the whole city: `SimulationCalculator` computes one set of supply and
demand figures per tick and applies them to every node identically. Coordinates are
used for identity, for the occupancy check, and to decide where to draw — nothing else.

Verified rather than assumed: the same nine buildings packed into one corner, strung
along a diagonal, and flung to opposite edges of the grid produce byte-identical
results after 200 ticks, down to each individual node's health.

So there is no reason to plan a layout, leave room for roads, or keep plants near what
they serve. Place things wherever is convenient — the only placement rule the game
enforces is one block per cell.

This is a genuine gap rather than a considered design: there is no adjacency, service
radius or distance cost anywhere in the domain, and the spec never discussed one. If
that ever changes, the characterisation test in `simulation_calculator_test.exs` fails
and takes this section with it.

## Why your first city dies

**On the third residential block.**

The city starts with free baseline capacity — 40 of every resource, no infrastructure
needed. A residential block draws `power 15`. Two blocks come to 30 and hold at full
health forever. The third makes 45, against a supply of 40, and from that moment the
city is dying.

| residential, no support | worst satisfaction | after 200 ticks    |
|-------------------------|--------------------|--------------------|
| 1–2                     | 1.0                | 100 health, stable |
| 3                       | 0.889              | every node dead    |
| 19                      | 0.14               | every node dead    |

## The one rule

**Keep every resource at 100% satisfaction, every tick.** There is no stable
slightly-overloaded state, because three mechanics compound:

* decay is **six times faster** than regeneration;
* supply is scaled by each producer's health, but **demand never is** — see
  `SimulationCalculator`'s moduledoc, which calls this asymmetry out as deliberate;
* **`:offline` is cosmetic.** A dead node still draws its full demand while producing
  almost nothing. A collapsing district actively poisons the rest of the city.

So any shortfall reduces supply, which deepens the shortfall. The totals row at the
foot of the legend shows all four satisfaction figures; the lowest one is the only
number that matters, because each node takes the worst of the resources it consumes.
That lowest figure is exactly what the metrics' *Tightest* line reports, so it stays on
screen with the legend collapsed.

## What a support set can carry

Measured by simulation — add residential until the city no longer holds at full
health:

<!-- generated:capacities -->
| support set | support tiles | min residential | max residential | total tiles | residential per tile |
|---|---|---|---|---|---|
| 1 power, 1 water, 1 industrial, 1 road | 4 | 3 | **5** | 9 | 0.56 |
| 2 power, 2 water, 1 industrial, 1 road | 6 | 3 | **9** | 15 | 0.6 |
| 3 power, 3 water, 2 industrial, 2 road | 10 | 6 | **15** | 25 | 0.6 |
<!-- /generated:capacities -->

About 0.6 residential per tile is the ceiling. Two practical consequences:

**Build producers first.** Demand arrives instantly and in full, so a consumer placed
before its support starts doing damage on the very next tick.

**Place one node at a time and watch the panel.** Because the four resources are
coupled — a power plant needs water, a water plant needs power — adding a producer to
fix one shortfall creates demand elsewhere. The binding constraint moves rather than
disappearing.

Those capacity figures include the one-off baseline 40, so a district that works is not
automatically tileable: the second copy has no baseline of its own. As the city grows
the ratio converges to roughly **3 power : 3 water : 2 industrial : 2 road hubs per 13
residential**.

The min residential column exists for the same reason the max one does, just at the other
end: `industrial` and `commercial` need workers, and residential is the only source of
labour, so build the support set with too few residential and those blocks starve for
staff instead of power or water — the shortfall just shows up in a different column.

## Rescuing a city that is already dying

**You cannot build your way out of a collapse.** Every one of these was simulated
against 19 dead residential blocks:

| added to the dead city                     | satisfaction on the first tick | outcome                         |
|--------------------------------------------|--------------------------------|---------------------------------|
| 4 power, 3 water, 2 industrial, 1 road     | 0.676                          | still all dead                  |
| 4 power, 3 water, 3 industrial, 3 road     | 0.888                          | still all dead                  |
| **5 power, 4 water, 3 industrial, 3 road** | **1.000**                      | **full recovery, 34/34 online** |

The near-misses are the lesson. The rescue has to lift **all four** resources to 1.0
on the first tick; miss one — traffic, in the first row — and the new plants decay
alongside everything else. Under-building is indistinguishable from not building, and
costs the same tiles.

Two approaches that work:

1. **Bulldoze back to what the baseline supports** (two residential), then rebuild
   properly. Verified to recover to full health.
2. **Add the entire support set in one go.** Removing dead consumers first makes this
   much cheaper, since their demand is what you are fighting.

Mixed rescues are fine: five dead residential plus a fresh 1/1/1/1 recovers completely.
Health returns at a flat rate, so a node at zero is back to full in 100 ticks.

## How long you have to react

Decay is proportional to the shortfall, which means small deficits are slow and
survivable while large ones are not.

| satisfaction | health lost per tick | full to dead |
|--------------|----------------------|--------------|
| 0.98         | 0.12                 | ~14 minutes  |
| 0.90         | 0.60                 | ~3 minutes   |
| 0.68         | 1.94                 | ~52 seconds  |

## Reference

### Free baseline capacity

Available with no infrastructure placed at all.

<!-- generated:baseline -->
| power | water | waste | traffic | labour |
|---|---|---|---|---|
| 40 | 40 | 40 | 40 | 0 |
<!-- /generated:baseline -->

### What each type produces

Production is scaled by the node's health, so a plant at 50% health supplies half.

<!-- generated:production -->
| type | produces |
|---|---|
| `industrial` | waste 90 |
| `park` | waste 8 |
| `power_plant` | power 120 |
| `residential` | labour 4 |
| `road_hub` | traffic 60 |
| `water_plant` | water 100 |

Produce nothing at all: `commercial`.
<!-- /generated:production -->

### What each type consumes

Consumption is **never** scaled by health. This is the mechanic behind every death
spiral.

<!-- generated:consumption -->
| type | power | water | waste | traffic | labour |
|---|---|---|---|---|---|
| `commercial` | 22 | 8 | 14 | 9 | 8 |
| `industrial` | 40 | 25 | — | 8 | 12 |
| `park` | — | 18 | — | 2 | — |
| `power_plant` | — | 20 | 12 | 3 | — |
| `residential` | 15 | 12 | 10 | 6 | — |
| `road_hub` | 8 | — | 2 | — | — |
| `water_plant` | 25 | — | 6 | 2 | — |
<!-- /generated:consumption -->

Read `waste` and `traffic` as *capacity*: `industrial` supplies waste processing and
`road_hub` supplies road capacity, which residential and commercial then consume.

`park` is usually a trap — it trades a lot of water for a little waste capacity, so it
only pays when you have spare water and are waste-limited, which is rare given how much
`industrial` supplies.

### Health and timing

<!-- generated:constants -->
| rule | value |
|---|---|
| health regained per tick when every consumed resource is fully supplied | **+1** |
| health lost per tick, per unit of shortfall | **−6 × (1 − satisfaction)** |
| `:online` at | health ≥ 60 |
| `:degraded` at | health ≥ 20 |
| `:offline` below | health 20 |
| tick length | 1000 ms |
<!-- /generated:constants -->
