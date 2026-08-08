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
and satisfaction, per tick. Four of the six resources have a free baseline of 40 built
in — supply for power and water, absorption for waste and traffic; labour and money
have none, deliberately — see below. When the city is short of power, water, waste
disposal or labour, it automatically buys the missing amount for **1 money per unit**.
Purchased capacity appears in the supplied total, and the Metrics panel shows the cost
as *Automatic purchases*. Traffic cannot be bought.

**Show detail / Hide detail** collapses the legend to its type, count and cost columns,
which is how you make the window narrower — the six resource columns are most of its
width. Collapsing never takes away the type list, so you can still choose what to place,
and it never hides the metrics. The satisfaction figures go with the resource columns, so
while collapsed the metrics carry a *Tightest* line naming the resource in shortest supply.

### Build a house first

**Every block needs staff except the homes the staff live in.** Power plants, water
plants, transit hubs, parks, industry and commerce all draw labour; `residential` is the
only thing that produces it locally. Imported labour can bridge the gap while the treasury
lasts, but housing is the cheaper durable source.

Place one residential block before anything else. It needs no support on an empty grid,
earns 1 per tick, and never needs imports there.

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

## Why your first city runs out of runway

**The third residential block starts importing power.**

The city starts with free baseline capacity — 40 each of power, water, waste and
traffic, no infrastructure needed: enough to supply 40 power and 40 water, and enough
to absorb 40 waste and 40 traffic.

Waste is the one bad that keeps a score. Whatever you emit past your absorption
capacity stays in the ground as a **Landfill**, shown in the metrics panel, and it
is added to next tick's load — so a city that is 10 over runs 10 short, then 20,
then 30. The backlog drains at capacity minus emissions once you are back under,
which makes the exit from a waste spiral either an `industrial` block or fewer
emitters. Traffic does not work this way: a jam clears at the tick boundary, and
only waste accumulates.

Labour and money have no free baseline; they arrive only once you build for them. A
residential block draws `power 15`. Two blocks come to 30 and hold at full health forever.
The third makes 45, so the city buys 5 power per tick. Three houses earn only 3: the
treasury falls by 2 per tick even though every resource reads 100% supplied. Starting from
the grant, that buffer lasts about 200 ticks; once it is gone, health begins to fall.

Larger unsupported neighbourhoods exhaust the treasury faster, and seven houses already
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

## Your second city

The cheapest city that earns anything is three blocks — one house, one park, one
commercial, 75 in all, holding at full health and **+28 per tick** (see `park` in the
reference below). Build that first. It is a useful staging point: its income can pay for
some imports while you expand, but local infrastructure leaves a much larger margin.

Without imports, every possible fourth block overruns something:

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
already have takes eight, and a second shop wants another eight. The market now fills those
gaps if the treasury can pay; the table tells you what that convenience will cost each tick.

So the way forward is a power plant and a water plant. Those need *each other*: the power
plant drinks 20 water, the water plant draws 25 power, and neither fits beside the earner.
What is in the way is the shop. Its 22 power is exactly what leaves only 3 free — take it
out and the house and park draw 15, leaving 25, which is the water plant's draw to the
unit. Selling it is the import-free route; keeping it is faster, but makes the treasury pay
for the temporary shortfall.

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

**The shop goes last in the import-free sequence.** Putting it up earlier is now a valid
shortcut when you have priced the automatic purchases and kept enough cash for the next
construction.

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

Extra money can fund the other route, with the shop before the plants. Watch *Automatic
purchases* as well as the block prices: the market charge repeats every tick, so a large
treasury is runway rather than proof that the layout is sustainable.

## What a support set can carry

Measured by simulation — add residential until the city no longer holds at full
health:

<!-- generated:capacities -->
| support set | support tiles | min residential | max residential | total tiles | residential per tile |
|---|---|---|---|---|---|
| 2 power, 1 water, 1 industrial, 1 transit, 1 commercial | 6 | 1 | **7** | 13 | 0.54 |
| 2 power, 2 water, 1 industrial, 1 transit, 1 commercial | 7 | 2 | **10** | 17 | 0.59 |
| 3 power, 3 water, 2 industrial, 2 transit, 2 commercial | 12 | 3 | **14** | 26 | 0.54 |
<!-- /generated:capacities -->

These measured ceilings include sustainable market purchases where the support set's
income can pay for them. Two practical consequences:

**Build producers first.** Demand arrives instantly and in full, so a consumer placed
before its support starts an import bill on the very next tick. This is subordinate to
housing, though: a producer placed on an empty grid must buy its staff until housing
exists. See "Build a house first" above.

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
is the exception; reduce traffic demand or add transit capacity.

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
turn growth into drainage. Short of one of those routes, the rest of the city is free to
stay dead forever. Houses crowding
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

**Game over** is the case where the treasury can never rise again, so no command will ever be
affordable. The cheapest thing you can do is demolish, at 10, and the cheapest thing you can
build is a house, at 15, so below 10 you have no move at all. Two different things can make
that floor permanent, and a city needs only one of them.

**Stalled and broke** is the first. The clock has stopped, production is health-scaled and
therefore zero, so the balance cannot move. Nothing in the city can change on its own.

**Locked** is the second, and it does not look like death at all. If your upkeep is higher
than the most your city could *ever* earn — every block at 100 health — then the treasury
drains to zero and stays there however long you wait, because upkeep is not scaled by health
and income is. The smallest example is one house and one park: the park costs 3 a tick, the
house earns 1, and the house is fully supplied inside the free baseline so it holds 100 health
forever. Measured, that city is unchanged after 2,000 ticks — a healthy-looking house, a dead
park, an empty treasury, and nothing you can click. The banner calls this **City locked**
rather than dead, because the house really is alive; what has died is your ability to act.

The word for the underlying condition is **insolvent**, and it is the same one used above for a
support set with no commercial block. Insolvency on its own is not a crisis — the documented
opening sequence is insolvent for five of its seven stages, which is exactly what the grant is
for. It becomes fatal only when the treasury can no longer buy the way out.

So the game warns you first. While a city is insolvent and the fix is slipping out of reach,
the sidebar shows a **Rescue window** — how many ticks you have left before you can no longer
afford the cheapest single action that would fix it — and a banner names that action and its
price. Twelve ticks before the window closes, the banner turns into a warning. The window
counts down to losing the *fix*, not to reaching zero — you run out of options before you run
out of money, by however many ticks the fix's own price buys you. See "Running out of money"
above: the escape has to be bought while there is still something to buy it with.

Stalled, locked and stalled-and-broke all put a **Reset** button in the page header, beside the
theme toggle. It clears every block, returns the treasury to the opening grant, sets the tick
back to zero and discards the stored city. There is no confirmation and no undo.

The rescue-window warning does **not** put that button on screen, and that is deliberate: a
city you can still fix should not be offering you a one-click way to destroy it.

## Reference

### Free baseline capacity

Available with no infrastructure placed at all.

<!-- generated:baseline -->
| power | water | waste | traffic | labour | money |
|---|---|---|---|---|---|
| 40 | 40 | 40 | 40 | 0 | 0 |
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
| `power_plant` | — | -20 | +12 | +3 | -1 | — |
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

Parks are thirsty, and that is what bounds them. On the free baseline's 40 water exactly
one park fits — and it needs a house to staff it and a commercial block to cover its
upkeep, so the smallest city with a park in it is three blocks. Measured: water 38/40,
income +28 per tick, stable indefinitely. A second park needs a water plant, which needs
power. A neglected park is worse than none: amenity is scaled by health, its staffing and
water draw are not, so a dead park amplifies nothing while still costing everything.

### Automatic market purchases

| resource | price per unit | purchasable |
|---|---:|---|
| power | 1 money | yes |
| water | 1 money | yes |
| waste disposal | 1 money | yes |
| labour | 1 money | yes |
| traffic | — | no |

Net upkeep is reserved before imports. If the remaining treasury cannot cover every
eligible shortage, the same percentage of each is purchased. Money earned during a tick
becomes available for imports on the following tick.

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
