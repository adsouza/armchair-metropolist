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

### The map grows with the city

You start on a 2×2 grid — four cells. Place your third block and two more rows and
columns open up, giving you a 4×4; the twelfth opens a 6×6, and so on up to 32×32. The
grid opens whenever more than 70% of its cells are occupied, so you are never forced to
fill it completely before it gives you room.

New rows and columns appear at the right and bottom edges. Nothing you have already built
moves, and no block changes its coordinates — the map grows away from the corner you
started in, rather than shifting your city around.

The cells themselves shrink as the grid grows, so the whole map stays a comfortable size
on screen rather than running off the edge: it reaches close to its full width at 6×6
and stays around there from then on.

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
supplied at current health. For a bad, that same arrow can rise while the situation
worsens: a decaying `industrial` reads `-90 → -45`, which is less waste removed, not
more of the problem. A dash means the type does not touch that resource at all,
which is different from netting to zero. The totals row gives city-wide demand, supply
and satisfaction, per tick. Water supply has a free baseline of 30, waste absorption has 40;
traffic absorption starts at 20. Power, labour and money have no free baseline,
deliberately — see below. When the city is short of power, water, waste
disposal or labour, it automatically buys the missing amount for **1 money per unit**.
Purchased capacity appears in the supplied total, and the Metrics panel shows the cost
as *Automatic purchases*, broken down into one amber badge per resource. The same resource's
totals cell shows `+N bought`, so imported capacity is visibly distinct from local supply.
Each imported worker also adds **1 traffic demand** for that tick, shown separately as
*Imported-labour traffic*. Traffic cannot be bought.

**Show detail / Hide detail** collapses the legend to its type, count and cost columns,
which is how you make the window narrower — the six resource columns are most of its
width. Collapsing never takes away the type list, so you can still choose what to place,
and it never hides the metrics. The satisfaction figures go with the resource columns, so
while collapsed the metrics carry a *Tightest* line naming the resource in shortest supply.

### Build a house first

**Every block needs staff except the homes the staff live in.** Power plants, water
plants, transit hubs, parks, industry and commerce all draw labour; `residential` is the
only thing that produces it locally. Imported labour can bridge the gap while the treasury
lasts, but housing is the cheaper durable source and imported workers add commuter traffic.

Place one residential block before anything else. It supplies the workers the next block
will need, but with no free power it immediately imports 15 units. Its 1 income offsets
only one unit of that repeating bill, so build a power plant next rather than waiting.

This qualifies the "build producers first" rule below rather than replacing it: demand
still arrives instantly and in full, so a consumer placed before its support still does
damage. The order is **one house, then producers, then the rest.**

Money gives the same advice for a different reason. `residential` is the cheapest block at
15 and earns without consuming any money. It does not support itself indefinitely anymore:
the opening grant is buying its power until generation arrives. `commercial` earns thirty
times as much per tick, but placed by itself it has neither power nor workforce and decays
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

## Why your first city runs out of runway

**The first residential block starts importing power.**

The city starts with free baseline capacity of 30 water, 40 waste disposal and 20 traffic,
but **zero power**. The market keeps an unsupported house at 100% satisfaction by buying
all 15 power it needs.

Waste is the one bad that keeps a score. Whatever you emit past your absorption
capacity stays in the ground as a **Landfill**, shown in the metrics panel, and it
is added to next tick's load — so a city that is 10 over runs 10 short, then 20,
then 30. The backlog drains at capacity minus emissions once you are back under,
which makes the exit from a waste spiral either an `industrial` block or fewer
emitters. Traffic does not work this way: a jam clears at the tick boundary, and
only waste accumulates.

Power, labour and money have no free baseline; they arrive only once you build for them or
pay the market. One residential block draws `power 15` and earns 1, for a net treasury
drain of 14 per tick. Two draw 30 and earn 2, draining 28. Satisfaction still reads 100%
while those imports are affordable; once the treasury is gone, health begins to fall.

Larger unsupported neighbourhoods exhaust the treasury faster, and four houses already
exceed the unpurchasable traffic baseline. Imports buy time and can make a deliberately
import-dependent city viable, but they do not make capacity planning optional.

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

## Your first durable city

The useful four-block earner is one house, one power plant, one transit hub and one
commercial block, 175 in all. The plant supplies power, while the market supplies ten water
and six missing workers. Those commuters raise traffic demand from 18 to 24, but transit
raises capacity from 20 to 80. Income 31 minus 5 plant upkeep, 4 transit upkeep, 10 water
imports and 6 labour imports leaves **+6 per tick**. It is a good place to pause and save.

Without imports, every possible fourth block needs some additional local capacity:

<!-- generated:opening_wall -->
| add this to the earner | what overruns |
|---|---|
| `commercial` | labour 19/5 |
| `industrial` | labour 23/5 |
| `park` | water 58/30 |
| `power_plant` | labour 12/5 |
| `residential` | water 52/30 |
| `transit_hub` | labour 13/5 |
| `water_plant` | labour 12/5 |
<!-- /generated:opening_wall -->

The table is local demand against local plus baseline capacity; the market can cover power,
water, disposal and labour shortages if the treasury can pay. Traffic remains a hard wall.
The direct opening therefore builds transit before commerce, then lets that profitable core
fund the remaining support chain:

<!-- generated:opening -->
| # | place | cost | spent so far | tightest resource | money |
|---|---|---|---|---|---|
| 1 | `residential` | 15 | 15 | power 15/15 | −14 |
| 2 | `power_plant` | 80 | 95 | water 32/32 | −6 |
| 3 | `transit_hub` | 40 | 135 | water 32/32 | −10 |
| 4 | `commercial` | 40 | 175 | water 40/40 | +6 |
| 5 | `water_plant` | 70 | 245 | waste 44/44 | +6 |
| 6 | `residential` | 15 | 260 | waste 54/54 | +2 |
| 7 | `park` | 20 | 280 | waste 54/54 | +9 |
| 8 | `park` | 20 | 300 | waste 54/56 | +12 |

Total 300, against an opening grant of 400. The finished city nets +12 per tick. Every stage is fully supplied on all five physical resources — the `tightest resource` column is demand against available supply, including purchases, so step 1's `15/15` is imported power.

Measured: starting cold from the grant, this holds at full health with up to **6 ticks (6 s) between placements**. Slower than that and the treasury empties mid-sequence.
<!-- /generated:opening -->

Read the `tightest resource` column downwards and you can watch the binding constraint
move: imported power for the first house, water through the commercial core, then waste
disposal while the second house and parks arrive.

Two things about that table are worth saying out loud.

**The money column is negative for three stages, and that is fine.** It includes both upkeep
and automatic purchases: step 1 is 1 income minus 15 imported power, step 2 adds the plant's
5 upkeep and two imported water, and step 3 adds transit's 4. Commerce arrives next and
reverses the flow to +6.

**Transit goes before the shop.** Without it, the house, plant and shop generate 18 ordinary
traffic plus 4 commuter traffic against a baseline of 20. Transit turns that immediate
shortfall into enough headroom for the commercial core and later growth.

### If you need longer between clicks

The only deadline is reaching commerce at step 4. Before then the first house imports power,
then the power plant and transit hub run upkeep and water-import deficits. The measured
6-tick spacing above is the safe limit from a cold start. Once the four-block core is
running, waiting increases the treasury instead of consuming it.

<!-- generated:opening_pace -->
After step 4, the transit-backed commercial core earns +6 per tick. There is no extra savings target for slower play: waiting funds the remaining blocks.
<!-- /generated:opening_pace -->

Until step 4, watch *Automatic purchases* as well as block prices: the market charge repeats
every tick. After step 4, the core's +6 flow is what makes a large treasury sustainable
rather than temporary runway.

## What a support set can carry

Measured by simulation — add residential until the city no longer holds at full
health:

<!-- generated:capacities -->
| support set | support tiles | min residential | max residential | total tiles | residential per tile |
|---|---|---|---|---|---|
| 2 power, 1 water, 1 industrial, 1 transit, 1 commercial | 6 | 3 | **6** | 12 | 0.5 |
| 2 power, 2 water, 1 industrial, 1 transit, 1 commercial | 7 | 4 | **8** | 15 | 0.53 |
| 3 power, 3 water, 2 industrial, 2 transit, 2 commercial | 12 | 5 | **11** | 23 | 0.48 |
<!-- /generated:capacities -->

These measured ceilings include sustainable market purchases where the support set's
income can pay for them. Two practical consequences:

**Build producers first.** Demand arrives instantly and in full, so a consumer placed
before its support starts an import bill on the very next tick. This is subordinate to
housing, though: a producer placed on an empty grid must buy its staff until housing
exists, and those imported workers consume traffic capacity. See "Build a house first"
above.

**Place one node at a time and watch the panel.** Because the six resources are
coupled — a power plant needs water, a water plant needs power — adding a producer to
fix one shortfall creates demand elsewhere. The binding constraint moves rather than
disappearing.

Those capacity figures include the one-off baselines, so a district that works is not
automatically tileable: the second copy has no baseline of its own. As the city grows
the ratio converges to roughly **3 power : 3 water : 2 industrial : 2 transit hubs : 2
commercial per 12 residential**. Commercial belongs in that ratio now, not as an
optional add-on: a residential block's own income (money 1) can't cover what it costs
the water plants and transit hubs it needs, so a support set without a commercial block is
insolvent — the treasury drains over the game's lifetime even while every other resource
reads 100% satisfied. That word has a precise meaning the game acts on, and a city that stays
insolvent long enough ends up locked and unplayable; see "When the city stops" below for the
warning you get first and the way back out.

The min residential column exists for the same reason the max one does, just at the other
end: **every block needs staff except the homes the staff live in**. Power plants, water
plants, transit hubs, parks, industry and commerce all draw labour, and residential is the
only local source. A support set with fewer homes must import its missing workers; the
minimum is where the whole economy, including that market bill, remains sustainable.

## Rescuing a city that is already dying

The treasury is now a direct rescue resource. Before placing anything, read *Automatic
purchases*: if the city can afford every power, water, disposal and labour shortfall, those
imports immediately count toward satisfaction and can let dead blocks regenerate. Traffic
is the exception; imported labour makes it worse, so reduce traffic demand, replace the
commuters with local workers, or add transit capacity.

Three rescue routes remain useful:

1. **Let the market bridge a temporary gap.** This is best when damaged producers are
   already present and will need fewer imports as they heal. Current-tick income cannot be
   spent until the next tick, so the treasury shown now is the hard first-tick limit.
2. **Bulldoze demand.** This lowers both the recurring import bill and the local capacity
   required. Account for the whole series of 10-money demolition fees before starting.
3. **Build durable supply.** Power plants, water plants, industry, transit, housing and
   parks replace recurring purchases with local capacity, but their own inputs arrive
   immediately and may increase the import bill before they reduce it.

Waste disposal deserves special attention: buying disposal can clear the current landfill,
but every unprocessed unit that remains carries into the next tick. A partial disposal
budget slows the spiral; it does not erase it.

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

The treasury pays three different bills: construction, demolition, and automatic imports.
Construction and demolition are one-off charges; imports repeat every tick. The market
reserves net upkeep first and then splits the remaining import budget proportionally across
every eligible shortage. If it can fund only half the total bill, power, water, disposal and
labour each receive half of what they need.

Only money already in the treasury can be imported with. Income produced during this tick
arrives at its end and becomes spendable on the next one. That one-tick lag matters most at
zero: a city may earn money while still taking one tick of unassisted shortage.

At an empty treasury the old baseline cliffs still apply. Two dead houses on a clean grid
draw 30 power and heal; three draw 45 and cannot. With money on hand, the city buys that
five-power gap and all three can heal, at 5 per tick, until the treasury or the gap is gone.

**Getting out is easier the earlier you start.** Compare the recurring import bill with the
one-off fix. Spending 20 every tick to bridge a power gap may be reasonable for two ticks
while a plant heals and ruinous as a permanent design. Conversely, a small labour import can
be cheaper than an emergency building that introduces larger power, water and traffic loads.

Leave enough treasury for the command that ends the dependency. A market-supported city can
look perfectly healthy while its remaining runway is falling every tick; the *Automatic
purchases* line is the warning that satisfaction alone cannot provide.

**You do get told, but only about the permanent kind.** Spending your treasury down is normal
and the game says nothing; what it watches for is upkeep exceeding the most your city could
*ever* earn, which no amount of waiting fixes. Once that is true and the fix is getting close to
unaffordable, the sidebar shows a **Rescue window** in ticks and a banner names the one cheapest
action that would fix it, with its price. Act inside that window and the city is fine; miss it
and you reach the locked state described in "When the city stops" below, where there is nothing
left to press but Reset.

## How long you have to react

Decay is proportional to the shortfall, which means small deficits are slow and
survivable while large ones are not.

| satisfaction | health lost per tick | full to dead |
|--------------|----------------------|--------------|
| 0.98         | 0.12                 | ~14 minutes  |
| 0.90         | 0.60                 | ~3 minutes   |
| 0.68         | 1.94                 | ~52 seconds  |

## When the city stops

A city **stalls** when every block sits at zero health, at least one of its inputs is
short **after automatic purchases**, and the landfill is not draining. A funded power,
water, disposal or labour gap therefore prevents a stall; an unfunded gap or a traffic
shortage can still freeze the city. Health and status are a genuine fixpoint at that point:
production scales with health and so is zero, consumption does not scale and so is
unchanged, and every tick would recompute the same health and status for every block. The
landfill does not always share that sameness — a *drowning* city, one whose backlog is
still growing rather than merely holding steady, would keep adding to it tick after tick
even while health never moves, which is exactly why the landfill needs its own condition
rather than being read off health alone. Either way the engine stops ticking once it
detects the fixpoint, and the tick counter stops with it.

Stalling is not the same as being beyond help, and the difference is the treasury. A
frozen city's balance is frozen too — it no longer drains to the upkeep of water plants,
transit hubs and parks — so whatever was in the bank when the city stalled is still there.

**Building anything restarts the clock; demolishing restarts it if it leaves at least one
surviving node fully supplied, if it leaves nothing at all, or if it leaves the landfill
draining** — cutting waste demand back under what the city's capacity can absorb. A new
block goes up at full health, and "every block at zero" is what the stall is, so one
placement of any type is enough to start the ticks again — though the new block is then
subject to the same shortage that killed the rest, and a city that is still short will
stall again once it dies. The empty-grid case is the edge of the same rule: an empty grid
has no block at zero health, so it is never stalled — demolishing the very last dead block
always restarts the clock, with nothing left in the city to run.

The landfill route is the odd one out: it can restart the clock without healing anything.
If a demolition cuts emissions below disposal capacity, the backlog begins draining and
the city is no longer at a fixpoint even while every block remains at zero. Buying enough
disposal has the same effect and may clear the landfill immediately; buying only part can
turn growth into drainage.

With no free power, an unfunded dead house has no self-healing exception: even one is
stalled at zero. Money in the bank can change that calculation because market purchases
count as supply. For example, cutting four dead houses to three costs 10 and leaves demand
for 45 imported power; if that money remains, traffic is also back under its 20 baseline
and the clock restarts. That may buy only one
tick rather than a recovery — if the treasury empties while the city still has no local
power, it can stall again.

**Game over** is the case where the treasury can never rise again, so no command will ever be
affordable. The cheapest thing you can do is demolish, at 10, and the cheapest thing you can
build is a house, at 15, so below 10 you have no move at all. Two different things can make
that floor permanent, and a city needs only one of them.

**Stalled and broke** is the first. The clock has stopped, production is health-scaled and
therefore zero, so the balance cannot move. Nothing in the city can change on its own.

**Locked** is the second, and it does not look like death at all. If your upkeep is higher
than the most your city could *ever* earn — every block at 100 health — then the treasury
drains to zero and stays there however long you wait, because upkeep is not scaled by health
and income is. The smallest stable example is one house, one power plant and one water
plant: local infrastructure covers every physical resource, but the two plants cost 10 a
tick against a maximum income of 1. At an empty treasury all three remain healthy forever
and nothing can be clicked. The banner calls this **City locked** rather than dead, because
the house really is alive; what has died is your ability to act.

The word for the underlying condition is **insolvent**, and it is the same one used above for a
support set with no commercial block. Insolvency on its own is not a crisis — the documented
opening sequence is insolvent at its second and third stages, which is exactly what the grant is
for. It becomes fatal only when the treasury can no longer buy the way out.

So the game warns you first. While a city is insolvent and the fix is slipping out of reach,
the sidebar shows a **Rescue window** — how many ticks you have left before you can no longer
afford the cheapest single action that would fix it — and a banner names that action and its
price. Twelve ticks before the window closes, the banner turns into a warning. The window
counts down to losing the *fix*, not to reaching zero — you run out of options before you run
out of money, by however many ticks the fix's own price buys you. See "Running out of money"
above: the escape has to be bought while there is still something to buy it with.

Once you change a city, a **Reset** button appears in the page header beside the theme toggle.
It is available whether the city is thriving, rescuable, stalled or locked, so an economic
softlock never traps you in that city. Reset clears every block, returns the treasury to the
opening grant, sets the tick back to zero and discards the stored city. The button asks for
confirmation because there is no undo; it stays hidden only while the city is equivalent to
the untouched opening state.

## Reference

### Free baseline capacity

Available with no infrastructure placed at all.

<!-- generated:baseline -->
| power | water | waste | traffic | labour | money |
|---|---|---|---|---|---|
| 0 | 30 | 40 | 20 | 0 | 0 |
<!-- /generated:baseline -->

### Per-block effect, scaled by health

Each figure is one block's effect on that resource, scaled by the block's health — a plant
at 50% health delivers half. Power, water, labour and money are goods: you want them to
rise. Waste and traffic are bads: you want them to fall.

<!-- generated:production -->
| type | effect |
|---|---|
| `commercial` | money +30 |
| `industrial` | waste -90 |
| `park` | waste -8 |
| `power_plant` | power +120 |
| `residential` | labour +5, money +1 |
| `transit_hub` | traffic -60 |
| `water_plant` | water +100 |

Every type has a health-scaled effect.
<!-- /generated:production -->

### Per-block effect, never scaled by health

The other side of the ledger, and it is **never** scaled by health. This is the mechanic
behind every death spiral: a dying block draws its full power and emits its full waste.

<!-- generated:consumption -->
| type | power | water | waste | traffic | labour | money |
|---|---|---|---|---|---|---|
| `commercial` | -22 | -8 | +14 | +9 | -8 | — |
| `industrial` | -40 | -25 | — | +8 | -12 | — |
| `park` | — | -18 | — | +2 | -1 | -3 |
| `power_plant` | — | -20 | +12 | +3 | -1 | -5 |
| `residential` | -15 | -12 | +10 | +6 | — | — |
| `transit_hub` | -8 | — | +2 | — | -2 | -4 |
| `water_plant` | -25 | — | +6 | +2 | -1 | -5 |
<!-- /generated:consumption -->

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

Parks are thirsty, and that is what bounds them. On the free baseline's 30 water, one park
and one house land exactly at 30 — but without generation their imported power and the
park's upkeep still drain the treasury. Adding commerce raises water demand to 38, so the
market buys eight water until a water plant arrives. A second park raises that trio to 56
water and makes local treatment urgent. A neglected park is worse than none: amenity is
scaled by health, its staffing and water draw are not, so a dead park amplifies nothing
while still costing everything.

### Automatic market purchases

| resource | price per unit | purchasable | side effect |
|---|---:|---|---|
| power | 1 money | yes | — |
| water | 1 money | yes | — |
| waste disposal | 1 money | yes | — |
| labour | 1 money | yes | +1 traffic per unit |
| traffic | — | no | — |

Net upkeep is reserved before imports. If the remaining treasury cannot cover every
eligible shortage, the same percentage of each is purchased. Money earned during a tick
becomes available for imports on the following tick. Commuter traffic is based on labour
actually purchased, not the unfunded portion of a labour shortage, and clears each tick.

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
