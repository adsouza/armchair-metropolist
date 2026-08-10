# Playing Armchair Metropolist

The simulation is unforgiving in a specific way, and knowing that way is most of the
game. This guide's reference tables and capacity figures are generated from the domain
code and checked by `test/docs/playing_guide_test.exs`, so they cannot drift away from
the rules — see [TESTING.md](../TESTING.md).

## The controls

There are four everyday controls, and the middle two are the same gesture on the same
square — worth knowing, because nothing on screen separates them:

* **click a type in the legend** — selects it for placing;
* **click an empty cell** — places the currently selected type;
* **click a placed block** — undoes it for a full refund during opening planning, then
  demolishes it after the simulation begins;
* **click Begin sim** — ends opening planning and starts the city and bond clocks.

Later, a prosperous city's labour unions can pause the clock with a contract ultimatum.
That prompt is a real choice: accept permanently higher variable costs, or refuse and lose
part of the local workforce to a strike. An active strike can be settled later from its banner.

Placing charges the block's price and is refused
outright if the treasury will not cover it — the legend dims the rows you cannot afford,
and a refused click says what it wanted and what you have. Before Begin sim, removing a
planned block restores its entire construction price and can be repeated without limit.
After Begin sim, demolition charges a flat fee, which is less than the cheapest block but
is not nothing: a city with an empty treasury cannot tear anything down either.

## Choose the bond before you build

A new city has no grant and no spendable cash. First authorize one opening municipal bond
issue; its proceeds become the treasury immediately. The opening issue is a fixed-term
commitment, not a renewable credit line, and only Reset returns to those three choices. A
narrow one-time commercial bridge can become available later; it is described below.

<!-- generated:bonds -->
| issue | proceeds | principal/tick | first interest | first payment | total interest | final payment |
|---|---:|---:|---:|---:|---:|---:|
| Lean | 250 | 2.50 | 1.25 | 3.75 | 63.13 | 2.51 |
| **Balanced · recommended** | 400 | 4.00 | 2.00 | 6.00 | 101.00 | 4.02 |
| Generous | 550 | 5.50 | 2.75 | 8.25 | 138.88 | 5.53 |
<!-- /generated:bonds -->

Authorizing an issue enters **opening planning**. The clock is stopped: there is no upkeep,
market spending, health change or debt service, and planned blocks can be removed for full
refunds. Place at least one block, revise the plan as often as needed, then click **Begin
sim**. That click starts both the simulation and a **20-tick debt-service grace period**.
The transitions to ticks 1 through 20 have no debt service; the transition to tick 21 takes
the first payment.

The goal box directly above the city grid acts as an opening coach during this period. Its suggested goals are
outcomes, not mandatory construction steps: first cover power locally, then establish income,
then establish an initial local workforce and expand it only when doing so improves operating margin,
and make sure essential resources and projected purchases leave a positive operating margin.
Once those checks pass it suggests reviewing the layout and beginning the simulation. A warning,
default or terminal condition always replaces the suggestion.

After the holiday, each tick reserves operating upkeep first, then bond debt service, then
automatic imports. The legend's *money* column remains operating income minus upkeep: bond
service is shown separately in the Municipal bond panel and never masquerades as a block's
load. Interest is 0.5% of outstanding principal per servicing tick, while one hundredth of
the original principal matures each tick. Payments decline as principal falls, and the
100th servicing tick makes every remaining principal due.

### The one-time commercial bridge

When a city's maximum operating income is lower than its base upkeep, the simulator calculates
how many commercial blocks are needed to close that structural cash-flow gap. As soon as the
treasury falls below those blocks' combined current construction cost, it offers one commercial
bridge bond. Damage and non-money shortages do not disqualify the city: those pressures are
often exactly why emergency financing is useful. This remains a one-time rescue, not a general
second bond market.

The quote is calculated from the live city rather than fixed. It raises the treasury to the
full construction budget for every required commercial block **plus six projected ticks of the
city's actual cash outflow**, rounded up to a whole unit. The projection uses the real tick calculation, so
operating costs, market purchases, changing income and scheduled opening-bond service are all
included. Issuing the bridge starts its own 20-tick payment holiday immediately; it then
amortizes over 100 servicing ticks at the same 0.5% interest rate. Opening-bond service is paid
first when both series owe money.

The bridge can be issued only once. Its card disappears once the treasury can again cover the
required commercial construction, the operating gap closes, or the issue is accepted. The
server recomputes the quote on the click so a stale browser cannot borrow against conditions
that no longer exist. A missed payment on either series pauses new construction until the
past-due balance clears.

If cash is short, interest and serial principal remain past due. **Default pauses new
construction**, but it does not remove blocks or stop demolition; later cash is applied to
arrears before the current principal maturity. Optional redemption at par opens after 20
servicing ticks, clears interest arrears first, and then reduces principal. Redeem 25 is a
convenient partial action, while Redeem all uses the exact current balance.

The simulation clock is the bond clock. A stalled city, a city still in opening planning,
and a city with no viewer advancing it accrue nothing. Closing the page does not create
offline interest, and missed payments never extend the fixed maturity.

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

Hover either grid square and the tooltip names the action it will perform — full-refund undo
during opening planning, demolition afterwards. Either ordinary action may name one you
cannot afford: a placement when the balance is under that type's cost, or a post-start
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
traffic absorption starts at 30. Power, labour and money have no free baseline, deliberately —
see below. Injuries, disease and crime are persistent stocks shown outside this matrix. When the
city is short of power, water, waste
disposal or labour, it automatically buys the missing amount for **1 money per unit**.
Each totals cell turns orange at 10% headroom or less and red once available supply no longer
meets demand; purchased capacity counts as available supply in that warning.
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

### Choose an opening approach

**Every block needs staff except the homes the staff live in.** Power plants, water
plants, transit hubs, hospitals, parks, police stations, schools, industry and commerce all
draw labour; `residential` is the only thing that produces it locally. Imported labour can
bridge the gap while the treasury
lasts, but housing is the cheaper durable source and imported workers add commuter traffic.

Opening planning removes the need for a single click order. A housing-first plan supplies
workers locally but needs power. A utility-first plan establishes generation but initially
imports its staff. A commercial-first plan imports 22 power and 8 labour against 30 income,
so it holds its operating balance level during the grace period while you add local support.
The baseline 30 traffic can absorb that shop's 9 ordinary trips plus 8 commuters.

The tradeoffs begin only after Begin sim. Before clicking it, use the projected resource and
market figures to decide whether the current plan has enough runway to correct its shortages.
Housing remains the cheapest durable workforce, producers replace recurring imports, and
commerce supplies the income that makes either approach sustainable. Spend the whole issue
on things that cannot earn and the city still has no way back — see "Running out of money"
below.

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

The city starts with free baseline capacity of 30 water, 40 waste disposal and 30 traffic,
but **zero power**. The market keeps an unsupported house at 100% satisfaction by buying
all 15 power it needs.

Waste, injuries, disease and crime keep score. Whatever waste you emit past absorption
stays in the ground as a **Landfill**, shown in the metrics panel, and is added to
the next tick's load. Injuries and disease likewise persist until hospital capacity
treats them. Traffic itself still clears at the tick boundary, but its healthy threshold falls
linearly from 100% of available capacity at zero utilization to 80% at full utilization. Demand
above that moving threshold creates one injury per ten excess trips. With one residential block,
outbreaks occur every 49 ticks; every additional
residential block shortens that interval by three ticks, down to a 10-tick minimum. Each outbreak
adds two disease cases per residential block. The Metrics panel shows both untreated stocks.
The first time either health stock becomes positive during a play session, the goal box explains the
cause and response. It stays out of the way when the city already has a hospital.

Injuries, disease and crime are not separate legend columns because only their treatment blocks
directly change them. The hospital, police-station and school rows state their per-block treatment
rates, while Metrics shows each untreated stock.

Injuries and disease suppress the workforce before the next resource calculation. Ten untreated
cases per effective residential block reduce local labour to zero, with smaller burdens
reducing every residential block proportionally. Parks and schools multiply what remains; they
cannot amplify sick or injured workers back into the workforce. A healthy hospital treats ten
injuries and ten disease cases per tick, and treatment falls with the hospital's health.

Crime is a large-city pressure. The first **10 workers left after all labour demand is met** are
harmless; beyond that allowance, every five excess workers add one crime per tick. Crime persists
until health-scaled school or police capacity clears it. A healthy police station removes 12 crime
per tick, while a healthy school removes 6. Untreated crime reduces every commercial block's money
production: 20 crime per effective commercial block cuts it to zero, with smaller burdens reducing
income proportionally. The *Crime* line in Metrics shows both the stock and the current commerce
multiplier.

Power, labour and money have no free baseline; they arrive only once you build for them or
pay the market. One residential block draws `power 15` and earns 1, for a net treasury
drain of 14 per tick. Two draw 30 and earn 2, draining 28. Satisfaction still reads 100%
while those imports are affordable; once the treasury is gone, health begins to fall.

Larger unsupported neighbourhoods exhaust the treasury faster. Five houses fill the
unpurchasable traffic baseline and cross its dynamically lowered healthy threshold, creating
injuries; a sixth exceeds capacity outright. Imports buy time and can make a deliberately
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
foot of the legend shows satisfaction for the six columnar resources. The lowest of all
eight tracked resources is the only number that matters, because each node takes the worst
of the resources it consumes. That lowest figure is exactly what the metrics' *Tightest*
line reports, so it stays on screen with the legend collapsed.

## Your first durable city

The useful four-block earner is one house, one power plant, one transit hub and one
commercial block, 175 in all. The plant supplies power, while the market supplies ten water
and six missing workers. Those commuters raise traffic demand from 18 to 24, but transit
raises capacity from 30 to 90. Income 31 minus 5 plant upkeep, 4 transit upkeep, 10 water
imports and 6 labour imports leaves **+6 per tick**. It is a good place to pause and save.

Without imports, every possible fourth block needs some additional local capacity:

<!-- generated:opening_wall -->
| add this to the earner | what overruns |
|---|---|
| `commercial` | labour 19/5 |
| `hospital` | labour 15/5 |
| `industrial` | labour 23/5 |
| `park` | water 58/30 |
| `police_station` | labour 14/5 |
| `power_plant` | labour 12/5 |
| `residential` | water 52/30 |
| `school` | labour 15/6.25 |
| `transit_hub` | labour 13/5 |
| `water_plant` | labour 12/5 |
<!-- /generated:opening_wall -->

The table is local demand against local plus baseline capacity; the market can cover power,
water, disposal and labour shortages if the treasury can pay. Traffic remains a hard wall.
This example includes transit before commerce to bank headroom for later growth, then lets
that profitable core support the remaining chain. It is a plan, not a required order: during
opening planning all eight Balanced blocks can be placed, removed and reordered before any
resource changes:

<!-- generated:opening -->
| # | place | cost | spent so far | tightest resource | projected money/tick |
|---|---|---|---|---|---|
| 1 | `residential` | 15 | 15 | power 15/15 | −14 |
| 2 | `power_plant` | 80 | 95 | water 32/32 | −6 |
| 3 | `transit_hub` | 40 | 135 | water 32/32 | −10 |
| 4 | `commercial` | 40 | 175 | water 40/40 | +6 |
| 5 | `water_plant` | 70 | 245 | waste 44/44 | +6 |
| 6 | `residential` | 15 | 260 | waste 54/54 | +2 |
| 7 | `park` | 20 | 280 | waste 54/54 | +9 |
| 8 | `park` | 20 | 300 | waste 54/56 | +12 |

Total 300, against the recommended 400 bond issue. The finished city nets +12 per tick. Every stage is fully supplied on all seven physical resources — the `tightest resource` column is demand against available supply, including purchases, so step 1's `15/15` is imported power.

| issue | principal | opening plan | reserve when sim begins | first payment | total interest |
|---|---:|---|---|---:|---:|
| Lean | 250 | plan the four-block earning core, begin, then save and grow | 75 | 3.75 | 63.13 |
| **Balanced · recommended** | **400** | plan all eight blocks, then begin | **100** | **6.00** | **101.00** |
| Generous | 550 | plan all eight blocks, then begin | 250 | 8.25 | 138.88 |

All three issues include an untimed opening-planning phase with full-refund undo. Begin sim starts both the city clock and a 20-tick debt-service grace period; the bond then has 100 servicing ticks, level principal, and 0.5% interest per tick.
<!-- /generated:opening -->

Read the `tightest resource` column downwards and you can watch the binding constraint
move: imported power for the first house, water through the commercial core, then waste
disposal while the second house and parks arrive.

Two things about that table are worth saying out loud.

**The money column is negative for three stages, and that is fine.** It includes both upkeep
and automatic purchases: step 1 is 1 income minus 15 imported power, step 2 adds the plant's
5 upkeep and two imported water, and step 3 adds transit's 4. Commerce arrives next and
reverses the flow to +6.

**Transit is early, but no longer mandatory before the shop.** Without it, the house, plant
and shop generate 18 ordinary traffic plus 4 commuter traffic against a baseline of 30, so
the three-block core works. Adding transit in the example raises capacity to 90 before later
housing and support blocks consume that margin.

### When to begin the simulation

There is no deadline between planning clicks. Balanced can place the complete eight-block
opening for 300, revise it freely, and begin with 100 still in reserve. Generous can do the
same with 250. Lean cannot afford all eight before starting: plan its four-block earning core
for 175, click Begin sim with 75 in reserve, then let that core fund the remaining support
chain. Once the clock starts, the 20-tick debt-service grace period is the time to turn any
remaining imports into durable capacity.

<!-- generated:opening_pace -->
The four-block commercial core has +6 of operating cash flow per tick. Debt service is separate: Lean can begin at the core, save through its 20-tick grace period, and then cover a first payment of 3.75. Balanced and Generous can plan all eight blocks before beginning; the finished opening's +12 flow covers their first payments of 6.00 and 8.25.
<!-- /generated:opening_pace -->

During planning, *Projected purchases* describes what the current plan will need once the
clock starts; no money moves yet. After Begin sim, the core's +6 flow is what makes a large
treasury sustainable rather than temporary runway.

### A no-demolition path from Balanced

The two parks in the opening are useful infrastructure, not temporary scaffolding. The intended
stable route never asks you to remove them: save the opening surplus, then expand utilities,
income, waste disposal and health care together. The exact checkpoint below is simulated by the
guide tests rather than estimated by hand.

<!-- generated:balanced_growth -->
Keep every opening block. Let the finished Balanced opening save until tick 38, when its treasury reaches 451.06, then add `hospital`, `commercial`, `power_plant`, `water_plant`, `industrial` for 350 total. No demolition is required. That leaves a 101.06 operating reserve. The expanded city has +6 of operating cash flow before debt service and traffic 76/90; its hospital clears the periodic health burden while that surplus retires the bond.
<!-- /generated:balanced_growth -->

## What a support set can carry

Measured by simulation — add residential until the city no longer holds at full
health:

<!-- generated:capacities -->
| support set | support tiles | min residential | max residential | total tiles | residential per tile |
|---|---|---|---|---|---|
| 2 power, 2 water, 1 industrial, 1 transit, 1 commercial, 1 hospital | 8 | 5 | **6** | 14 | 0.43 |
| 3 power, 3 water, 2 industrial, 2 transit, 2 commercial, 1 hospital | 13 | 7 | **9** | 22 | 0.41 |
| 7 power, 6 water, 4 industrial, 4 transit, 3 commercial, 2 hospital | 26 | 18 | **22** | 48 | 0.46 |
<!-- /generated:capacities -->

These measured ceilings include sustainable market purchases where the support set's
income can pay for them. Two practical consequences:

**Build producers first.** Demand arrives instantly and in full, so a consumer placed
before its support starts an import bill on the very next tick. This is subordinate to
housing, though: a producer placed on an empty grid must buy its staff until housing
exists, and those imported workers consume traffic capacity. See "Choose an opening approach"
above.

**Place one node at a time and watch the panel.** Because the nine resources are
coupled — a power plant needs water, a water plant needs power — adding a producer to
fix one shortfall creates demand elsewhere. The binding constraint moves rather than
disappearing.

Those capacity figures include the one-off baselines, so a district that works is not
automatically tileable: the second copy has no baseline of its own. As the city grows
the ratio converges to roughly **3 power : 3 water : 2 industrial : 2 transit hubs : 2
commercial : 1 hospital per 9 residential**. Commercial belongs in that ratio now, not as an
optional add-on: a residential block's own income (money 1) can't cover what it costs
the water plants and transit hubs it needs, so a support set without a commercial block is
insolvent — the treasury drains over the game's lifetime even while every other resource
reads 100% satisfied. That word has a precise meaning the game acts on. Build commerce while
it is affordable; if the treasury falls below the full cost of the commerce needed to close
the gap, the one-time bridge above may reopen it. A city that cannot qualify, or has already used the bridge, can still end
up locked and unplayable; see "When the city stops" below.

The min residential column exists for the same reason the max one does, just at the other
end: **every block needs staff except the homes the staff live in**. Power plants, water
plants, transit hubs, hospitals, parks, police stations, schools, industry and commerce all draw labour, and residential is the
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

**Damage that falls evenly costs workforce in step with the housing; damage that falls hardest on parks or schools costs more.** The
multiplier is a ratio, and both sides are scaled by health, so damage that falls evenly
on housing and its multipliers cancels out — the workforce shrinks in step with the housing, no
faster. What moves a multiplier is *uneven* damage: let the parks or schools rot while the housing
holds and the bonus shrinks, and the labour column falls faster than the block count
suggests. Read the *Workforce* line in the metrics rather than counting parks on the grid,
because the health-weighted ratios matter, not the raw totals.

Health returns at a flat rate once conditions are met, so a node at zero is back to
full in 100 ticks.

## Running out of money

The treasury pays four kinds of bills: construction, demolition, block upkeep, and automatic imports.
Construction and demolition are one-off charges; upkeep and imports repeat every tick. The market
reserves net upkeep first and then splits the remaining import budget proportionally across
every eligible shortage. If it can fund only half the total bill, power, water, disposal and
labour each receive half of what they need.

Organized labour is the other large-city pressure. The first wage demand arrives when the
treasury rises above **1,000**, with another 10-point demand for every additional 1,000-money
band, up to 70%. The clock pauses for each ultimatum. Accepting permanently raises construction,
demolition, upkeep and market prices to the demanded wage level. Refusing preserves the current
cost level but removes the same share of local labour in a strike, multiplying workforce supply
just as injuries and disease do. The *Wage inflation* and *Workforce · Strike* lines show the two
sides of the choice. Fixed bond principal and scheduled debt service are contractual, so wage
inflation does not rewrite them.

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
for 45 imported power; if that money remains, traffic is also back under its 30 baseline
and the clock restarts. That may buy only one
tick rather than a recovery — if the treasury empties while the city still has no local
power, it can stall again.

**Game over** is the case where the treasury can never rise again and no commercial bridge
offer remains, so no command will ever be affordable. The cheapest thing you can do is
demolish, at 10, and the cheapest thing you can build is a house, at 15, so below 10 you have
no ordinary move at all. Two different things can make that floor permanent, and a city needs
only one of them.

**Stalled and broke** is the first. The clock has stopped, production is health-scaled and
therefore zero, so the balance cannot move. Nothing in the city can change on its own.

**Locked** is the second, and it does not look like death at all. If your upkeep is higher
than the most your city could *ever* earn — every block at 100 health — then the treasury
drains to zero and stays there however long you wait, because upkeep is not scaled by health
and income is. One house, one power plant and one water plant demonstrate the underlying
condition: local infrastructure covers every physical resource, but the two plants cost 10 a
tick against a maximum income of 1. At an empty treasury all three remain healthy forever.
That exact city now receives the bridge offer because one commercial block fixes it. If the
bridge has already been used, the banner calls the terminal state **City locked** rather than
dead: the house really is alive; what has died is your ability to act.

The word for the underlying condition is **insolvent**, and it is the same one used above for a
support set with no commercial block. Insolvency on its own is not a crisis — the documented
opening sequence is insolvent at its second and third projected stages, which is exactly what
the opening reserve is for. It becomes fatal only when the treasury can no longer buy
the way out.

So the game warns you first. While a city is insolvent and the fix is slipping out of reach,
the sidebar shows a **Rescue window** — how many ticks you have left before you can no longer
afford the cheapest single action that would fix it — and a banner names that action and its
price. Twelve ticks before the window closes, the banner turns into a warning. The window
counts down to losing the *fix*, not to reaching zero — you run out of options before you run
out of money, by however many ticks the fix's own price buys you. See "Running out of money"
above: the escape has to be bought while there is still something to buy it with.

Once you change a city, a **Reset** button appears in the page header beside the theme toggle.
It is available whether the city is thriving, rescuable, stalled or locked, so an economic
softlock never traps you in that city. Reset clears every block, stock and health burden,
returns the treasury to zero,
sets the tick back to zero and discards the stored city. You then authorize a new bond issue.
The button asks for confirmation because there is no undo; it stays hidden only while the city
is equivalent to the untouched, unissued state.

## Reference

### Free baseline capacity

Available with no infrastructure placed at all.

<!-- generated:baseline -->
| power | water | waste | traffic | injuries | disease | crime | labour | money |
|---|---|---|---|---|---|---|---|---|
| 0 | 30 | 40 | 30 | 0 | 0 | 0 | 0 | 0 |
<!-- /generated:baseline -->

### Per-block effect, scaled by health

Each figure is one block's effect on that resource, scaled by the block's health — a plant
at 50% health delivers half. Power, water, labour and money are goods: you want them to
rise. Waste, traffic, injuries, disease and crime are bads: you want them to fall.

<!-- generated:production -->
| type | effect |
|---|---|
| `commercial` | money +30 |
| `hospital` | injuries -10, disease -10 |
| `industrial` | waste -90 |
| `park` | waste -8 |
| `police_station` | crime -12 |
| `power_plant` | power +120 |
| `residential` | labour +5, money +1 |
| `school` | crime -6 |
| `transit_hub` | traffic -60 |
| `water_plant` | water +100 |

Every type has a health-scaled effect.
<!-- /generated:production -->

### Per-block effect, never scaled by health

The other side of the ledger, and it is **never** scaled by health. This is the mechanic
behind every death spiral: a dying block draws its full power and emits its full waste.

<!-- generated:consumption -->
| type | power | water | waste | traffic | injuries | disease | crime | labour | money |
|---|---|---|---|---|---|---|---|---|---|
| `commercial` | -22 | -8 | +14 | +9 | — | — | — | -8 | — |
| `hospital` | -20 | -15 | +10 | +4 | — | — | — | -4 | -6 |
| `industrial` | -40 | -25 | — | +8 | — | — | — | -12 | — |
| `park` | — | -18 | — | +2 | — | — | — | -1 | -3 |
| `police_station` | -12 | -6 | +4 | +3 | — | — | — | -3 | -5 |
| `power_plant` | — | -20 | +12 | +3 | — | — | — | -1 | -5 |
| `residential` | -15 | -12 | +10 | +6 | — | — | — | — | — |
| `school` | -18 | -12 | +8 | +6 | — | — | — | -4 | -8 |
| `transit_hub` | -8 | — | +2 | — | — | — | — | -2 | -4 |
| `water_plant` | -25 | — | +6 | +2 | — | — | — | -1 | -5 |
<!-- /generated:consumption -->

`hospital` removes ten injuries and ten disease cases per tick at full health. That
treatment is capacity, so a hospital at 50% health removes five of each while still
drawing its full utilities, staffing and upkeep. Injuries and disease cannot be bought
away on the market; durable cities must include enough healthy hospitals to clear both
ordinary traffic injuries and periodic outbreak spikes.

`police_station` and `school` remove crime in the same health-scaled way. Police are the focused,
cheaper response: 70 to build for 12 crime treatment. Schools cost more at 120 and treat 6 crime,
but also multiply the labour supplied by housing. One healthy school adds five gross workers until
the city reaches **one school per four residential blocks**; at that ratio the school multiplier
caps at ×1.25. Schools still consume four staff themselves, so the labour cell shows their net value.

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
| injuries | — | no | requires hospitals |
| disease | — | no | requires hospitals |
| crime | — | no | requires schools or police stations |

Net upkeep is reserved before imports. If the remaining treasury cannot cover every
eligible shortage, the same percentage of each is purchased. Money earned during a tick
becomes available for imports on the following tick. Commuter traffic is based on labour
actually purchased, not the unfunded portion of a labour shortage, and clears each tick.
The 1-money entries are base prices; accepted wage inflation multiplies them.

### What each type costs

<!-- generated:costs -->
| type | cost to build |
|---|---|
| `commercial` | 40 |
| `hospital` | 100 |
| `industrial` | 60 |
| `park` | 20 |
| `police_station` | 70 |
| `power_plant` | 80 |
| `residential` | 15 |
| `school` | 120 |
| `transit_hub` | 40 |
| `water_plant` | 70 |

These are base construction prices. Once a running city's treasury exceeds 1000, unions demand 10% higher wages per additional 1,000, up to ×1.7. Accepting permanently raises construction, demolition, upkeep and market prices; refusing removes the same share of local labour in a strike. Demolishing anything has a base cost of 10, whatever it was. A new city starts with no cash; authorize a 250, 400 or 550 opening municipal bond issue before construction. Those proceeds are debt, not a grant. A structurally draining city may later receive one dynamically quoted commercial bridge when its treasury falls below the combined current cost of the commercial blocks needed to close its operating gap. The quote also covers six projected ticks of expenses.
<!-- /generated:costs -->

### Health and timing

<!-- generated:constants -->
| rule | value |
|---|---|
| health regained per tick when every consumed resource is fully supplied | **+1** |
| health lost per tick, per unit of shortfall | **−6 × (1 − satisfaction)** |
| labour supply, multiplied per park per housing block | **+1 × (parks ÷ housing)** |
| that multiplier's ceiling, at 1 park per housing block | **×2** |
| labour supply, multiplied per school per housing block | **+1 × (schools ÷ housing)** |
| that multiplier's ceiling, at 0.25 school per housing block | **×1.25** |
| excess labour before crime begins | **10** |
| crime created beyond that allowance | **+0.2 per worker per tick** |
| untreated crime that suppresses one commercial block's income | **20** |
| first union wage demand begins above a treasury of | **1000** |
| each accepted demand adds to variable costs | **+10%** |
| each refused demand removes from local labour | **−10%** |
| healthy traffic ceiling | **100% at no utilization, falling linearly to 80% at full utilization** |
| injuries above that ceiling | **+1 per 10 excess traffic** |
| disease outbreak | **+2 per residential; every 49 ticks with one home, 3 ticks sooner per additional home (minimum 10)** |
| untreated cases that suppress one residential block's labour | **10** |
| `:online` at | health ≥ 60 |
| `:degraded` at | health ≥ 20 |
| `:offline` below | health 20 |
| tick length | 1000 ms |
<!-- /generated:constants -->
