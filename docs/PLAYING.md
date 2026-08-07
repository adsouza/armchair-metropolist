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

Hover either grid square and the tooltip names the action it will perform — though either
may name one you cannot afford: a placement when the balance is under that type's cost, a
demolition when it is under the flat fee. The dimmed legend row and the refused click are
what tell you. Demolishing
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

## Your second city

The cheapest city that earns anything is three blocks — one house, one park, one
commercial, 75 in all, holding at full health and **+28 per tick** (see `park` in the
reference below). Build that first. It is also a dead end, and the shape of the dead end
is the most useful thing on this page.

**Nothing you can add to it works.** Not one of the seven:

<!-- generated:opening_wall -->
| add this to the earner | what overruns |
|---|---|
| `commercial` | labour 17/10 |
| `industrial` | labour 21/10 |
| `park` | water 56/40 |
| `power_plant` | water 58/40 |
| `residential` | power 52/40 |
| `transit_hub` | power 45/40 |
| `water_plant` | power 62/40 |
<!-- /generated:opening_wall -->

Three different walls, and none of them is money. The free baseline is already carrying 37
of its 40 power and 38 of its 40 water, so five of the seven overrun one of those on the
tick they go up. `commercial` and `industrial` overrun those too, but they run out of
something scarcer first: one house and one park staff ten workers, of which the shop you
already have takes eight, and a second shop wants another eight.

So the way forward is a power plant and a water plant. Those need *each other*: the power
plant drinks 20 water, the water plant draws 25 power, and neither fits beside the earner.
What is in the way is the shop. Its 22 power is exactly what leaves only 3 free — take it
out and the house and park draw 15, leaving 25, which is the water plant's draw to the
unit. **You cannot own a shop while you build the waterworks.**

That is why the second city is a *sequence* and not a next step, and why it goes up with
nothing earning:

<!-- generated:opening -->
| # | place | cost | spent so far | tightest resource | money |
|---|---|---|---|---|---|
| 1 | `residential` | 15 | 15 | power 15/40 | +1 |
| 2 | `park` | 20 | 35 | water 30/40 | −2 |
| 3 | `water_plant` | 70 | 105 | power 40/40 | −7 |
| 4 | `power_plant` | 80 | 185 | waste 28/48 | −7 |
| 5 | `residential` | 15 | 200 | waste 38/48 | −6 |
| 6 | `park` | 20 | 220 | waste 38/56 | −9 |
| 7 | `commercial` | 40 | 260 | waste 52/56 | +21 |

Total 260, against an opening grant of 400. The finished city nets +21 per tick. Every stage is fully supplied on all five physical resources — the `tightest resource` column is demand against supply, so `40/40` is at capacity and not over it.

Measured: starting cold from the grant, this holds at full health with up to **4 ticks (4 s) between placements**. Slower than that and the treasury empties mid-sequence.
<!-- /generated:opening -->

Read the `tightest resource` column downwards and you can watch the binding constraint
walk: power while the baseline is carrying everything, water once the park is in, power
again at the knife-edge, then waste for the rest of the run. This is the same "the binding
constraint moves rather than disappearing" from the section below, seen one block at a
time.

Two things about that table are worth saying out loud.

**The money column is negative for five stages, and that is fine.** Money is the one
resource whose surplus survives a tick, and a shortfall it covers costs nothing — the
treasury is what pays the plants' and parks' upkeep until the shop arrives to take over.
What the grant buys you here is not blocks, it is the right to take your time.

**The shop goes last.** This sharpens the "one house, then producers, then the rest" rule
above rather than contradicting it: `commercial` is emphatically "the rest", and putting it
up early is the one mistake this whole sequence is arranged to avoid.

### If you need longer between clicks

The sequence above has a deadline only because the grant is finite — every stage is fully
supplied, so nothing is decaying; the treasury is simply draining. Bank more first and the
deadline goes away.

You cannot bank it with the shop unbuilt, because nothing else earns. So do it the other
way round: **build the three-block earner, let it run, then sell the shop.** Selling puts
you back at step 2 of the table above — one house and one park — with a full treasury and
the same five placements ahead of you. Demolition costs 10, which is the whole price of
the detour.

<!-- generated:opening_pace -->
| time between placements | bank this much first |
|---|---|
| 10 ticks (10 s) | 600 |
| 20 ticks (20 s) | 1000 |
| 30 ticks (30 s) | 1200 |
| 60 ticks (60 s) | 2000 |
<!-- /generated:opening_pace -->

Do not use the extra money to take the *other* route, the tempting one that puts the shop
up before the plants. No size of treasury rescues that: health decays at a rate set by the
size of the shortfall, and the treasury is not one of the terms. A city short of water
loses health just as fast with 2000 in the bank as with 20.

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

**Dead housing supplies no labour, and every type but `residential` draws some — so a
staffed block added to a city whose housing has died starves from its first tick, and
cannot regain a point of health until some housing has.** Once every residential block is
dead (health 0), it produces zero labour — production is health-scaled, same as everything
else — and `industrial` and `commercial` both need labour to hold their own health.
Simulated against 19 dead residential blocks: adding 5 power, 4 water, 3 industrial and 3
transit hubs — a combination that reaches full satisfaction on power, water, waste and
traffic simultaneously — still fails. The fresh `industrial` block starves for workers
from the very first tick, decays, and its falling waste output drags the rest of the city
down before the dead residential can recover on power and water alone. Measured: every
node's health is still 0.0 after 150 ticks.

That measurement drove `SimulationCalculator` directly for the full 150 ticks, to make the
point stick. A player never watches that happen: every block sitting at zero health with
every one of them still short is exactly the condition the engine stops on, so the game
freezes on the frozen board well before tick 150, not 150 more ticks of decay arriving on
screen. See "When the city stops" below.

The trap is the labour dependency, not the upkeep: `industrial` and `commercial`
need living residential to staff them, and dead residential cannot staff anything, no
matter how much power and water arrives on the same tick. Prices make that rescue worse
rather than better — those fifteen blocks cost 980 to build, and a city whose housing and
shops are all dead earns nothing to put towards it.

Two approaches work without waiting on labour to recover:

1. **Bulldoze back to what the baseline supports** (two residential, no `industrial` in
   the mix) and let them heal on power, water, waste and traffic alone — none of which
   residential needs labour or money for. Verified: both nodes return to 100 health
   within 100 ticks.

   That has a price now. Cutting a nineteen-block city back to the two houses the baseline
   supports means seventeen demolitions, which is 170 — and a city whose money producers
   are all dead earns nothing to pay it with. Start bulldozing while the treasury can cover
   the whole cut: stopping part way earns nothing back, because a house regains health only
   when all four of the resources it draws are fully supplied, and every house you have not
   removed yet is still drawing its full share of them.
2. **Never let residential fully die in the first place.** Add support while some
   residential is still alive — this is the "build producers first" advice above,
   and it is the only way to keep labour (and, once a commercial block exists, income)
   flowing rather than having to restart it from zero.

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
stay dead*.
A block regains health only when every resource *it* draws is fully supplied,
so each stays dead while anything on its own list is short. Housing's list is power, water,
waste and traffic — every one of which has a free baseline — so cut back until what the
houses still standing draw fits inside it, and dead housing heals itself with an empty
treasury and no further help: measured, two dead houses and 0 in the bank are at full
health in 100 ticks, having earned 99 on the way. That is approach 1 above, finished.

The cliff is arithmetic, and it is the one that killed your first city: a house draws 15
power against a baseline of 40, and dead blocks draw in full, so two dead houses heal and
three never do. That makes bulldozing all or nothing. Demolition stays *available* while
the treasury holds 10, but 10 buys exactly one block, the bill is 10 a block, and nothing
is earned until the cut is finished — nineteen dead houses cut back to three still earn
zero over 400 ticks. Nineteen down to two is 170, and 169 is not close: it leaves you three
houses, 9 in the bank, and nothing the treasury will pay for — no demolition at 10, no
house at 15, and nothing earning to change that.

**Getting out is easier the earlier you start.** A house costs 15, needs no support on an
empty grid, and consumes no money, so on a clear grid one house is enough to start earning
again. Beside dead blocks it is two sums, not one.
A block regains health only when every resource *it* draws is fully supplied,
and the house's own list is power, water, waste and traffic —
so whether it survives turns on those four alone: its own share on top of
everything else still standing, against one shared pool. A shortfall in labour or money
cannot touch it, however severe, which is why a house can sit at full health beside a block
that never recovers. Whether *that* block recovers is the other sum, over what it draws: a
house supplies labour and money, and none of the four that dead housing goes short of, so no
number of houses adds a drop of what dead housing needs.

The two sums can disagree, so there is no single order. Two dead houses heal on their own,
and a third placed beside them leaves all three dead, because housing draws the same four
resources the baseline is already carrying for the dead ones — so where the house would
not fit, demolish first. A dead power plant goes the other way: it is short of one unit of
labour and nothing else the baseline cannot cover, so building the house first heals both
and starts earning, while demolishing first spends 10 that does nothing toward the house.
Read what the dead blocks draw — and what the house you would add draws — before choosing
what to spend on.

Demolishing one block and then rebuilding has a floor of 25 — 10 for the removal, 15 for
the house — and below it that order is the fatal one. On a single dead `industrial` with 15
in hand, demolishing leaves 5, the rebuild is refused, and an empty grid with 5 in it is
where the city ends. Building first on the same 15 recovers: both blocks die, but the house
earns while it goes down, and that pays to clear
the `industrial` afterwards — which leaves the dead house drawing only what the baseline
covers, so it heals back to 100 on its own. When the treasury cannot cover both gestures,
check what building first would earn you before spending on the demolition, because income
collected on the way down can pay for a removal that the treasury cannot.

## How long you have to react

Decay is proportional to the shortfall, which means small deficits are slow and
survivable while large ones are not.

| satisfaction | health lost per tick | full to dead |
|--------------|----------------------|--------------|
| 0.98         | 0.12                 | ~14 minutes  |
| 0.90         | 0.60                 | ~3 minutes   |
| 0.68         | 1.94                 | ~52 seconds  |

## When the city stops

A city **stalls** when every block sits at zero health with at least one of its inputs
short. At that point nothing changes on its own: production scales with health and so is
zero, consumption does not scale and so is unchanged, and each tick recomputes the same
result. The simulation stops advancing, and the tick counter stops with it.

Stalling is not the same as being beyond help, and the difference is the treasury. A
frozen city's balance is frozen too — it no longer drains to the upkeep of water plants,
transit hubs and parks — so whatever was in the bank when the city stalled is still there.

**Building anything restarts the clock; demolishing restarts it if it leaves at least one
surviving node fully supplied, or if it leaves nothing at all.** A new block goes up at
full health, and "every block at zero" is what the stall is, so one placement of any type
is enough to start the ticks again — though the new block is then subject to the same
shortage that killed the rest, and a city that is still short will stall again once it
dies. The empty-grid case is the edge of the same rule: an empty grid has no block at
zero health, so it is never stalled — demolishing the very last dead block always
restarts the clock, with nothing left in the city to run. Short of that, the rest of the
city is free to stay dead forever. Houses crowding each other out under the free baseline
are the common case:
tear one house out of three and the remaining two are supplied and heal, tear one out of
five and the remaining four are still over the line and nothing moves. It is not the only
case: three dead houses beside one dead transit hub are stalled the same way, and
demolishing a house is still the fix, even though the transit hub is untouched — measured,
the two houses left recover to 100 health within 100 ticks while the transit hub, short of
labour and money, neither of which has a free baseline, sits at zero forever.

Not every dead-looking city is stalled. One or two houses alone recover from zero health
with an empty treasury: each draws 15 power against the free baseline of 40, so at `15n ≤
40` they are fully supplied even while dead, and they regenerate. Three do not — 45 against
40 — and that is the cliff.

**Game over** is the narrower case: the city has stalled *and* holds less than 10. The
cheapest thing you can do is demolish, at 10, and the cheapest thing you can build is a
house, at 15, so below 10 no command is affordable — and because the clock has stopped, the
balance will never rise again. Nothing in the city can change on its own. See "Running out
of money" above: the escape has to be bought while there is still something to buy it with.

Both states put a **Reset** button in the page header, beside the theme toggle. It clears
every block, returns the treasury to the opening grant, sets the tick back to zero and
discards the stored city. There is no confirmation and no undo.

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

Demolishing anything costs 10, whatever it was. A new city starts with 400.
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
