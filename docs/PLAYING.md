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

Both of those last two spend money. Placing charges the block's price and is refused
outright if the treasury will not cover it — the legend dims the rows you cannot afford,
and a refused click says what it wanted and what you have. Demolishing charges a flat
fee, which is less than the cheapest block but is not nothing: a city with an empty
treasury cannot tear anything down either.

Hover either grid square and the tooltip names the action it will perform. Demolishing
matters more than it looks: it is the only way to reduce demand, so it is how you get out
of a collapse — but at the fee above, which means the escape has to be bought while there
is still something to buy it with. See "Running out of money" below.

The legend — to the right of the grid on a wide enough window, stacked below it
otherwise — lists every type with how many you have placed, what it costs to build, and
its net effect on each resource. Where a type produces a resource and its buildings are
damaged, the cell shows both figures — `+360 → +210` means 360 rated, 210 actually
supplied at current health. A dash means the type does not touch that resource at all,
which is different from netting to zero. The totals row gives city-wide supply, demand and
satisfaction, per tick. Four of the six resources have a free baseline of 40 built into
that supply; labour and money have none, deliberately — see below.

**Show detail / Hide detail** collapses the legend to its type, count and cost columns,
which is how you make the window narrower — the six resource columns are most of its
width. Collapsing never takes away the type list, so you can still choose what to place,
and it never hides the metrics. The satisfaction figures go with the resource columns, so
while collapsed the metrics carry a *Tightest* line naming the resource in shortest supply.

### Build a house first

**Every block needs staff except the homes the staff live in.** Power plants, water
plants, transit hubs, parks, industry and commerce all draw labour; `residential` is the
only thing that supplies it. So a city with no housing cannot run *any* infrastructure —
measured, a lone power plant is offline in 14 ticks and dead in 17, and so is a lone
anything-that-needs-staff.

Place one residential block before anything else. It needs no support at all on an empty
grid, and it is the only block that will still be standing in a minute if you walk away.

This qualifies the "build producers first" rule below rather than replacing it: demand
still arrives instantly and in full, so a consumer placed before its support still does
damage. The order is **one house, then producers, then the rest.**

Money gives the same advice for a different reason. `residential` is the cheapest block at
15, it earns without consuming any money, and — alone on the empty grid — it is the only
block that stays healthy indefinitely, because it supplies its own workers. `commercial`
earns thirty times as much per tick, but placed by itself it has no workforce and decays
while it earns, so its income stops. Spend the whole grant on things that cannot earn and
the city has no way back — see "Running out of money" below.

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

The city starts with free baseline capacity — 40 each of power, water, waste and
traffic, no infrastructure needed. Labour and money have no free baseline; they arrive
only once you build for them. A residential block draws `power 15`. Two blocks come to
30 and hold at full health forever. The third makes 45, against a supply of 40, and
from that moment the city is dying.

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
foot of the legend shows all six satisfaction figures; the lowest one is the only
number that matters, because each node takes the worst of the resources it consumes.
That lowest figure is exactly what the metrics' *Tightest* line reports, so it stays on
screen with the legend collapsed.

## What a support set can carry

Measured by simulation — add residential until the city no longer holds at full
health:

<!-- generated:capacities -->
| support set | support tiles | min residential | max residential | total tiles | residential per tile |
|---|---|---|---|---|---|
| 2 power, 1 water, 1 industrial, 1 transit, 1 commercial | 6 | 5 | **5** | 11 | 0.45 |
| 2 power, 2 water, 1 industrial, 1 transit, 1 commercial | 7 | 6 | **7** | 14 | 0.5 |
| 3 power, 3 water, 2 industrial, 2 transit, 2 commercial | 12 | 10 | **12** | 24 | 0.5 |
<!-- /generated:capacities -->

About 0.5 residential per tile is the ceiling. Two practical consequences:

**Build producers first.** Demand arrives instantly and in full, so a consumer placed
before its support starts doing damage on the very next tick. This is subordinate to
housing, though: a producer placed on an empty grid has no staff and dies in 17 ticks.
See "Build a house first" above.

**Place one node at a time and watch the panel.** Because the six resources are
coupled — a power plant needs water, a water plant needs power — adding a producer to
fix one shortfall creates demand elsewhere. The binding constraint moves rather than
disappearing.

Those capacity figures include the one-off baseline 40, so a district that works is not
automatically tileable: the second copy has no baseline of its own. As the city grows
the ratio converges to roughly **3 power : 3 water : 2 industrial : 2 transit hubs : 2
commercial per 12 residential**. Commercial belongs in that ratio now, not as an
optional add-on: a residential block's own income (money 1) can't cover what it costs
the water plants and transit hubs it needs, so a support set without a commercial block is
insolvent — the treasury drains over the game's lifetime even while every other resource
reads 100% satisfied.

The min residential column exists for the same reason the max one does, just at the other
end: **every block needs staff except the homes the staff live in**. Power plants, water
plants, transit hubs, parks, industry and commerce all draw labour, and residential is the
only thing that supplies it — so build a support set with too few homes and those blocks
starve for staff instead of power or water, and the shortfall just shows up in a different
column.

## Rescuing a city that is already dying

**A city whose housing has died cannot be rescued by building on top of it.** Once every
residential block is dead (health 0), it produces zero labour — production is
health-scaled, same as everything else — and `industrial` and `commercial` both need
labour to hold their own health. Simulated against 19 dead residential blocks: adding
5 power, 4 water, 3 industrial and 3 transit hubs — a combination that reaches full
satisfaction on power, water, waste and traffic simultaneously — still fails. The fresh
`industrial` block starves for workers from the very first tick, decays, and its
falling waste output drags the rest of the city down before the dead residential can
recover on power and water alone. Measured: every node's health is still 0.0 after 150
ticks.

The trap is the labour dependency, not the upkeep: `industrial` and `commercial`
need living residential to staff them, and dead residential cannot staff anything, no
matter how much power and water arrives on the same tick. Prices make that rescue worse
rather than better — those fifteen blocks cost 980 to build, and a city whose housing and
shops are all dead earns nothing to put towards it.

Two approaches still work, because neither waits on labour to recover first:

1. **Bulldoze back to what the baseline supports** (two residential, no `industrial` in
   the mix) and let them heal on power, water, waste and traffic alone — none of which
   residential needs labour or money for. Verified: both nodes return to 100 health
   within 100 ticks.

   That has a price now. Cutting a nineteen-block city back to the two houses the baseline
   supports means seventeen demolitions, which is 170 — and a city whose money producers
   are all dead earns nothing to pay it with. Start bulldozing while the treasury can cover
   the whole cut: stopping part way earns nothing back, because nothing heals while the
   demand still standing outruns what is supplied.
2. **Never let residential fully die in the first place.** Add support while some
   residential is still alive — this is the "build producers first" advice above,
   and it is the only way to keep labour (and, once a commercial block exists, income)
   flowing through a rescue.

**Damage that falls evenly costs workforce in step with the housing; damage that falls hardest on the parks costs more.** The
multiplier is a ratio, and both sides are scaled by health, so damage that falls evenly
on housing and parks cancels out — the workforce shrinks in step with the housing, no
faster. What moves the multiplier is *uneven* damage: let the parks rot while the housing
holds and the bonus shrinks, and the labour column falls faster than the block count
suggests. Read the *Workforce* line in the metrics rather than counting parks on the grid,
because it is the ratio that matters, not the total.

Health returns at a flat rate once conditions are met, so a node at zero is back to
full in 100 ticks.

## Running out of money

The treasury is the one resource whose surplus survives a tick, and the one you can spend
to zero with no warning. Two things follow.

**Dead is not the same as unrecoverable — but the way back has a fixed price.** Money has
no free baseline: the only sources are `residential` and `commercial`, and production is
scaled by health, so a city whose housing and shops are all dead earns nothing *while they
stay dead*. They stay dead as long as the demand still standing outruns what is supplied.
Cut back until it fits inside the free baseline and dead housing heals itself, with an empty
treasury and no further help — measured, two dead houses and 0 in the bank are at full
health in 100 ticks, having earned 99 on the way. That is approach 1 above, finished.

The cliff is arithmetic, and it is the one that killed your first city: a house draws 15
power against a baseline of 40, and dead blocks draw in full, so two dead houses heal and
three never do. That makes the escape all or nothing. Demolition stays *available* while
the treasury holds 10, but 10 buys exactly one block, the bill is 10 a block, and nothing
is earned until the last one is gone — nineteen dead houses cut back to three still earn
zero over 400 ticks. Nineteen down to two is 170, and 169 is not close: it leaves you three
houses, 9 in the bank, and nothing the treasury will pay for. That is the only way to lose
for good — nothing earning, nothing healing, and too little saved to change either.

**Getting out is easier the earlier you start.** A house costs 15, needs no support on an
empty grid, and consumes no money, so on a clear grid one house is enough to start earning
again. Beside dead blocks it turns on one question: with the new house's own 15 power added,
does the demand still standing outrun what is supplied? The free baseline is one pool spread
across everything standing, and a house supplies none of what dead houses draw — no number
of houses would. So the house either fits, and survives, or it does not, and dies with them:
two dead houses heal on their own, and a third placed beside them leaves all three dead.

So where the demand still outruns supply, demolish first and then rebuild — and keep
enough in the treasury to do both. That order is not universal, though, because what a
dead block starves for may be exactly what a house supplies. A dead power plant is short
of one unit of labour and nothing else the baseline cannot cover, so building the house
first heals both and starts earning, while demolishing first spends 10 that does nothing
toward the house. Read what the dead blocks draw — and what the house you would add draws
— before choosing which gesture to spend on.

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
| power | water | waste | traffic | labour | money |
|---|---|---|---|---|---|
| 40 | 40 | 40 | 40 | 0 | 0 |
<!-- /generated:baseline -->

### What each type produces

Production is scaled by the node's health, so a plant at 50% health supplies half.

<!-- generated:production -->
| type | produces |
|---|---|
| `commercial` | money 30 |
| `industrial` | waste 90 |
| `park` | waste 8 |
| `power_plant` | power 120 |
| `residential` | labour 5, money 1 |
| `transit_hub` | traffic 60 |
| `water_plant` | water 100 |

Every type produces something.
<!-- /generated:production -->

### What each type consumes

Consumption is **never** scaled by health. This is the mechanic behind every death
spiral.

<!-- generated:consumption -->
| type | power | water | waste | traffic | labour | money |
|---|---|---|---|---|---|---|
| `commercial` | 22 | 8 | 14 | 9 | 8 | — |
| `industrial` | 40 | 25 | — | 8 | 12 | — |
| `park` | — | 18 | — | 2 | 1 | 3 |
| `power_plant` | — | 20 | 12 | 3 | 1 | — |
| `residential` | 15 | 12 | 10 | 6 | — | — |
| `transit_hub` | 8 | — | 2 | — | 2 | 4 |
| `water_plant` | 25 | — | 6 | 2 | 1 | 5 |
<!-- /generated:consumption -->

Read `waste` and `traffic` as *capacity*: `industrial` supplies waste processing and
`transit_hub` supplies transit capacity, which residential and commercial then consume.

`park` is how you get more workers out of the housing you already have. It produces no
labour itself — a city with no residential blocks has no workforce for a park to
amplify — but each one raises the labour your housing supplies, up to **one park per
residential block**, where the bonus stops at double. Past that ratio a park is pure
cost: it still drinks 18 water, still needs a groundskeeper, and adds nothing. The
legend's labour column tells you which side of that line you are on, showing `+4` while
parks are worth building and `-1` once they are not. At 20 a park is the second-cheapest
block, but it is not the cheapest workforce: a park adds 5 workers and consumes 1, so 20
buys 4 — while a house adds 5 and consumes none for 15. Parks win on the resources they
also fix, not on labour per coin. And past the cap the price is worse than wasted: 20 to
*lose* you a worker.

Parks are thirsty, and that is what bounds them. On the free baseline's 40 water exactly
one park fits — and it needs a house to staff it and a commercial block to cover its
upkeep, so the smallest city with a park in it is three blocks. Measured: water 38/40,
income +28 per tick, stable indefinitely. A second park needs a water plant, which needs
power. A neglected park is worse than none: amenity is scaled by health, its staffing and
water draw are not, so a dead park amplifies nothing while still costing everything.

### What each type costs

<!-- generated:costs -->
| type | cost to build |
|---|---|
| `commercial` | 40 |
| `industrial` | 60 |
| `park` | 20 |
| `power_plant` | 80 |
| `residential` | 15 |
| `transit_hub` | 40 |
| `water_plant` | 70 |

Demolishing anything costs 10, whatever it was. A new city starts with 150.
<!-- /generated:costs -->

### Health and timing

<!-- generated:constants -->
| rule | value |
|---|---|
| health regained per tick when every consumed resource is fully supplied | **+1** |
| health lost per tick, per unit of shortfall | **−6 × (1 − satisfaction)** |
| labour supply, multiplied per park per housing block | **+1 × (parks ÷ housing)** |
| that multiplier's ceiling, at 1 park per housing block | **×2** |
| `:online` at | health ≥ 60 |
| `:degraded` at | health ≥ 20 |
| `:offline` below | health 20 |
| tick length | 1000 ms |
<!-- /generated:constants -->
