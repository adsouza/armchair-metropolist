# Construction costs: building and demolishing spend money — design

**Date:** 2026-08-05
**Status:** designed, not yet implemented

## 1. Problem

Money is a treasury but not a budget. Since the money-and-labour branch (2026-08-02) the city
carries a balance that survives the tick boundary, and every other resource discards its surplus.
That balance is spent on *upkeep* — the water plants, transit hubs and parks that draw money each
tick — and nothing else. So a player with 500 in the bank and a player with 5 face exactly the same
decision when they click an empty cell: the city can be built out to any size instantly, and the
treasury only ever decides whether it then survives.

The result is that placement carries no cost and therefore no ordering pressure. `docs/PLAYING.md`
already advises building producers before consumers, but that is advice about *decay*, not about
affordability — nothing stops a player laying down forty blocks on tick one.

Construction and demolition should both spend from the treasury, so that what you can build is
bounded by what the city has earned.

### Non-goals

* **No debt.** The balance keeps its `max(0.0, …)` floor. An unaffordable command is refused, not
  financed. This preserves the existing invariant rather than replacing it.
* **No per-tick construction financing, staged builds, or build queues.** A charge is instantaneous
  and atomic with the placement.
* **No "reset city" control**, despite §8's dead end depending on one. It is a separate feature; see
  the follow-ups entry.
* **No change to the six-resource vocabulary.** Costs are not a seventh resource, and they never
  enter supply or demand. See §3.
* **No rebalancing of the wider economy** beyond `park`, which §4 addresses because this change
  would otherwise make an already-weak type strictly dead weight.

## 2. The prices

A third table joins the two `Node` already carries, and a flat demolition constant sits beside it,
so every price a player pays is in one module.

```elixir
@construction_cost_table %{
  power_plant: 80.0,
  water_plant: 70.0,
  industrial: 60.0,
  transit_hub: 40.0,
  commercial: 40.0,
  park: 20.0,
  residential: 15.0
}

@demolition_cost 10.0
```

Ordered by the block's weight in the city, so the curve reads as infrastructure-is-expensive.

**Whole numbers throughout**, following the precedent the money spec set when it chose 1 over 2.1
for residential income: a fractional cost would introduce a second precision rule, and §5 shows the
whole-number property is load-bearing for the treasury display rather than merely tidy.

**Demolition is flat across every type and cheaper than building anything.** Flat because teardown
does not care what stood there; cheaper because putting up a block is the larger undertaking. To
hold for *every* type that second property has to sit below the cheapest construction cost, so it
is an enforced invariant rather than an observation:

```elixir
assert Node.demolition_cost() < Enum.min(Enum.map(Node.types(), &Node.construction_cost/1))
```

Without that test a later balance patch dropping `residential` to 8 would silently make teardown
the expensive option, and nothing else in the suite would notice.

`Node.types/0` stays derived from `@production_table`, unchanged. A separate test asserts every
type in it has a construction cost, mirroring the existing
`Map.keys(baseline_capacity()) == Node.resources()` gate in `simulation_calculator_test.exs` — this
matters because `construction_cost/1` is a `Map.fetch!`, so a type missing from the cost table
raises at runtime instead of failing a test.

## 3. Where the charge lives

In the **Domain**, in `UseCases.ManageInfrastructure.place/4` and `demolish/3`. Both already take a
`CityMap` and return a new one, and `city_map.money` already exists, so a charge is a field update
on a struct the function owns.

```elixir
def place(city_map, x, y, type) do
  cond do
    not CityMap.in_bounds?(city_map, x, y)        -> {:error, :out_of_bounds}
    type not in Node.types()                     -> {:error, :unknown_type}
    CityMap.occupied?(city_map, x, y)             -> {:error, :occupied}
    city_map.money < Node.construction_cost(type) -> {:error, :insufficient_funds}
    true ->
      node = Node.new(x, y, type)

      city_map =
        city_map
        |> CityMap.put_node(node)
        |> CityMap.debit(Node.construction_cost(type))

      {:ok, {city_map, node}}
  end
end
```

`demolish/3` gains the same gate against `Node.demolition_cost()`, and returns
`{:error, :insufficient_funds}` leaving the node in place.

`CityMap.debit/2` is a new one-line function rather than an inline `%{map | money: …}`, so the
floor-at-zero rule lives in the entity that owns the field. It cannot actually reach the floor
given the gate above, and that is the point: the clamp documents that a balance is never negative
regardless of caller.

### Two ordering facts are load-bearing

**`unknown_type` must stay above the cost check.** `construction_cost/1` is a `Map.fetch!`, so an
unknown type reaching it raises `KeyError` instead of returning the error tuple the spec promises.
Reordering these two clauses turns a clean rejection into a crash inside a `GenServer.call`, which
takes the engine down and rolls the city back to its last checkpoint.

**`insufficient_funds` goes last.** A click on an occupied cell should report occupancy, not report
that you are broke about a build that was never possible on that cell anyway.

Both get a direct test, because both are invisible in review: every clause returns an error tuple,
so a wrong order still type-checks and still looks correct.

### Why not elsewhere

**Not in `CityEngine`.** That would put an economic rule in Infrastructure, where no test can reach
it without a running GenServer, and where the boundary graph forbids reaching
`Domain.Services.SimulationCalculator` at all.

**Not as extra `demanded(:money)` in `resource_stats/1`.** This is the important one. A construction
charge is a withdrawal from a stock, and demand is a per-tick flow. Folding it in would corrupt the
figure the legend's totals cell renders and re-create the self-contradicting cell that the money
spec's 2026-08-02 amendment exists to fix — a cell reading `13/23 · 100%`, whose printed percentage
is not derivable from the two numbers beside it. A test asserts that after a placement,
`resource_stats(:money).demanded` reflects upkeep only.

### No snapshot migration

Unlike the money-and-labour change, this one adds no persisted field:

* the only mutated state is `city_map.money`, which every stored city already carries, so
  `CityEngine.normalize_city_map/1` needs no new default and there is no `KeyError`-after-load
  crash-loop to guard against;
* `SnapshotVocabulary` is untouched — the cost table's keys are the same seven node-type atoms
  already interned via `@production_table` (in `node.ex`'s compressed `LitT` literals chunk, per
  that module's own note), its values are floats, and no new struct becomes reachable from
  `CityMap`.

Prices are rules, not state. Keeping them in a compile-time module attribute is what makes a
balance patch a code change rather than a data migration, and stops a saved city from disagreeing
with the current prices.

## 4. Park earns its place

`docs/PLAYING.md` already calls `park` "usually a trap — it trades a lot of water for a little
waste capacity, so it only pays when you have spare water and are waste-limited, which is rare
given how much `industrial` supplies." Attaching a 20 price tag to a type that is already a bad
deal would make it strictly dead weight, so its production side gains income:

| | before | after |
|---|---|---|
| produces | waste 8.0 | waste 8.0, **money 9.0** |
| consumes | water 18.0, traffic 2.0, money 3.0 | *unchanged* |

Net **+6 money per tick** at full health.

**The income goes on the production side, and its existing money consumption stays.** Those two
choices together are what keep `park` inside the mechanic the whole game is built on. Production is
scaled by health; consumption deliberately is not. So `produce 9, consume 3` nets +6 at full health
and **−3 at zero** — a neglected park becomes a liability, exactly like every other node. The
arithmetically-equal `produce 6, consume 0` would net +6 at full health and **0 at zero**, making
`park` the one type that neglect cannot punish. Net effect is not a complete specification of a
node in this engine: two tables with the same net differ at every health below 100, which is most of
the states that matter.

The legend needs no change to render this. `marginal_cell/2` already computes
`(produced || 0.0) - (consumed || 0.0)`, so the row shows `+6`, and `total_cell/2` already handles
a type appearing in both tables for one resource.

**Water stays at 18.0, deliberately.** That is `park`'s balancing constraint and the reason this
buff does not create a dominant opening. Against the free baseline of 40 water, two parks
(water 36, traffic 4) hold at full health indefinitely and net +12 money per tick for 40 spent; a
third needs 54 and starts decaying immediately. Scaling parks past two therefore requires a water
plant, which costs 70 and draws 25 power, which needs a power plant at 80. Parks bootstrap income
cheaply and then stop, which is a niche rather than an answer.

**Measured, not reasoned.** The proposed production table was applied and run through
`SimulationCalculator` for 500 ticks: one park nets +6/tick and holds health 100; two net +12/tick
and hold 100; three fall to water satisfaction 0.741 and every node is at health 0 within 200 ticks.
The cap is genuinely water, not money — the three-park city is *earning* +18/tick as it dies.

Worth recording because the same script falsified an assumption first: under the **current** tables
even a single park eventually dies. It produces no money, draws 3, and so drains the 500 grant in
about 167 ticks, after which money satisfaction drops below 1.0 and decay begins. So "park is a
trap" is stronger than `docs/PLAYING.md` currently states — it is not merely poor value, it is
terminal on a long enough timeline. That makes this buff a fix rather than a nicety.

The type keeps its character — thirsty, and only worth it when water is spare — while the payoff
changes from a resource that is rarely scarce to one that always is.

## 5. Presentation

### The treasury must be displayed floored, not rounded

`metrics/1` currently renders `Treasury: {round(@metrics.money)}`. With an affordability gate
downstream, `round` is a bug of exactly the kind the money spec's amendment was written to fix: a
balance of 79.6 displays as **80** while an 80-cost build is refused, and nothing on screen
explains it. A spendable balance must never round up.

```elixir
<p id="metrics-treasury">Treasury: {trunc(@metrics.money)}</p>
```

The domain comparison stays exact — `city_map.money < cost`, no epsilon. An epsilon here would be
the mistake, not the fix: there is no rounding downstream of it, the treasury either covers the cost
or it does not, and a tolerance would permit a build that drives the balance below zero and breaks
the no-debt invariant.

Flooring the display and comparing exactly agree with each other **because every cost is a whole
number** (§2): for integer-valued `cost`, `trunc(money) >= cost` exactly when `money >= cost`. That
is a real dependency between two decisions that look unrelated, so it is stated here and tested,
not left to be rediscovered when someone prices a block at 12.5.

Balances become non-round as soon as any producer is damaged — money income is
`1.0 * health / 100` per residential — so this is an ordinary state, not an edge case.

### The legend gains an always-visible `cost` column

Not `:if={@detail}`. Every resource column is detail-only, but price cannot be: the type rows stay
visible when the legend is collapsed precisely so a player can still choose what to place, and
choosing now spends money. The column is two digits wide, which is cheap in the only dimension that
matters here.

Unaffordable rows carry `data-affordable="false"` and an opacity class, and the cost cell gets a
`title` naming the shortfall — opacity alone is a visual-only signal. The comparison uses the raw
float, matching the domain gate exactly, so the dimming and the refusal can never disagree.

**The select button stays enabled.** Selecting an unaffordable type is harmless and frequently what
a player wants while waiting for income to accrue. Dimming reports a fact; disabling would block a
gesture that has no cost. `aria-pressed` keeps its current meaning, and no `aria-disabled` is added,
because the control genuinely is not disabled.

### Both wrap thresholds must be re-measured

[`simulator_live.ex`](../../../lib/armchair_metropolist_web/live/simulator_live.ex) carries
`max-[2010px]` expanded and `max-[1275px]` collapsed. An always-visible column widens **both**
matrices — where the money spec's two new resource columns moved only the expanded window, because
the collapsed table has no resource columns at all.

Follow the procedure recorded in that comment, in both collapse states: binary-search the real
viewport with `flexDirection` forced on the real inner div (not a clone), find `W_col` and `W_row`,
confirm at the boundary pixel, and set each constant to its window's **midpoint**.

**Do not compute the new values from the old ones plus an estimated column width.** That comment
records the arithmetic approach being wrong every time it was tried, because a `width: 100%` table
reports its container's width rather than its own content's.

### The refused click flashes

`SimulatorLive` currently discards every placement error —
`{:error, _reason} -> {:noreply, socket}`. This is the objection the money spec raised against
placement-time rules, and it is now ours to answer.

```
Not enough money: power_plant costs 80, treasury holds 40.
```

Named figures, not just a refusal, so the player learns the gap. Demolition gets the equivalent.
Both use the same floored treasury figure as the metrics line, so the two never disagree.

Delivered through the `:error` flash already wired into `Layouts.app`, so this is a `put_flash/3`
rather than new plumbing. The other three placement errors stay silent: `:out_of_bounds` is
unreachable from a grid that only renders in-bounds cells, and `:occupied` is nearly so, since the
node div sits above its cell and turns that click into a demolish.

## 6. Documentation

`docs/PLAYING.md` needs rework rather than edits, and its generated blocks are checked by
`test/docs/playing_guide_test.exs`, so the doc cannot be updated by hand alone.

**A new `<!-- generated:costs -->` block** joins `PlayingGuide.blocks/0`, listing each type's
construction cost, the flat demolition cost, and the opening grant of 500 — which currently appears
in no generated block and so lives only in a spec. Read out of `Node` and `CityMap`, so it cannot
drift.

**Two passages become outright false and must be rewritten**, not amended:

* *"Demolishing matters more than it looks: it is the only way to reduce demand, and therefore the
  only way out of a collapse."* Still the only way out, but it now costs 10 and can itself be
  refused. The guide has to state that a fully collapsed, broke city has no way out at all.
* The rescue section's *"Bulldoze back to what the baseline supports"* now has a price: nineteen
  blocks is 190, which a city with no living money producer can never raise. That approach works
  only if started before the treasury empties.

**Sections that need revising:** "The controls" (placing can now be refused, and both gestures
spend); "Build producers first" (which now trades against affordability, since producers are the
expensive types); and the `park` paragraph in the consumption reference, per §4.

The generated `production` and `consumption` blocks change with `park`'s tables. The `capacities`
block does not: its support sets exclude `park`, and it is computed by simulation.

## 7. Balance

**The opening grant buys one working city and nothing spare.** The smallest viable support set the
guide documents — 2 power, 1 water, 1 industrial, 1 transit, 1 commercial, 5 residential — costs
**445** of the 500, leaving 55: not enough for a second power plant, and one misplaced 80 puts the
first city out of reach until income accumulates.

| set | build cost | net money/tick once running |
|---|---|---|
| 2 residential (baseline only) | 30 | +2 |
| 2 park (baseline only) | 40 | +12 |
| 2 power, 1 water, 1 industrial, 1 transit, 1 commercial, 5 residential | 445 | +26 |
| 3 power, 3 water, 2 industrial, 2 transit, 2 commercial, 12 residential | 910 | +49 |

Every figure in the right-hand column is measured, not derived on paper: each set was built and run
through `SimulationCalculator` for 500 ticks, and all four hold at health 100 throughout. The build
costs are sums of §2.

**The game stays winnable from any state that still has a living money producer.** Two residential
blocks cost 30, sit inside the free baseline on all four flow resources, consume no money at all,
and hold 100 health indefinitely — so they yield +2/tick against zero money demand, without bound.
Two parks reach +12/tick for 40, also stable on the bare baseline, though unlike residential they
do draw money (3 each) and so net rather than gross their income. Either way a player who overspends
is slowed, never stuck.

**The opening is a real decision rather than a solved one.** Parks bootstrap money about six times
faster per tick than residential, but residential is the only source of labour, which `industrial`
and `commercial` both need. Neither dominates.

**Honest limitation: costs gate the rate of expansion and the first city, not a mature one.**
Payback periods are short — `commercial` recovers its 40 in under two ticks at +30, `park` its 20 in
between three and four. So a large city with healthy income can rebuild almost at will. That is the
intended shape and matches the genre: the constraint bites hardest when the player has least, and
fades as the city succeeds. It is recorded here so nobody later reads this spec as promising a
permanent budget constraint and "fixes" it by inflating prices.

## 8. Accepted consequences

**A fully collapsed city is permanently unrecoverable.** Chosen deliberately over the alternatives.
Two existing facts combine: `@baseline_capacity` gives money `0.0` — no free income, which the money
spec calls load-bearing because it is what forces `commercial` to be built — and production is
health-scaled. So once every residential and commercial block sits at health 0.0,
`supplied(:money)` is exactly `0.0`, the balance can only hold or drain, and a demolish costing 10
can never be paid. `docs/PLAYING.md` already documents that state as reachable and measured
("every node's health is still 0.0 after 150 ticks").

**The dead end is worse on desktop.** A web player can clear the session cookie — the city id lives
in a signed cookie via `EnsureCityId` — and get a fresh city. The desktop target has exactly one
city, shows no re-entry code, and nothing reaps it, so a dead city makes the app permanently inert.
A "reset city" control is the fix, is out of scope here, and goes in the follow-ups doc as needing a
decision.

**`residential` has the worst payback of any type** — 15 to build against +1/tick, fifteen ticks —
while being mandatory for labour. That is a coherent tension (housing is an investment, not a
revenue source) and is left as is.

**The first-city build order now matters twice**, for decay and for affordability, and those two
pressures do not point the same way: decay says build producers first, affordability says build the
cheap income first. That is the interesting part of the change, not a flaw, but it makes the game
harder to start and `docs/PLAYING.md` has to say so.

## 9. Testing

The follow-ups doc records nine tests on this project that **could not fail**, every one passing
review by reading and caught only by mutation. So the two rules it derived apply throughout: **no
`refute` without the positive case asserted first**, and **a test you have not seen fail is not yet
a test**. Each test below is broken-first and confirmed red before being trusted.

The coverage gate is 90% and the suite sits at 94.86%, with `Domain` and `UseCases` at 100% — so
the new domain code must be fully covered, not merely mostly.

### Mutation-sensitive cases

These are the ones that carry the design, named individually because each kills a specific mutation
that everything else would let through.

* **A balance exactly equal to the cost succeeds and leaves `0.0`.** Kills `<` flipped to `<=`.
  Built from a hand-constructed `CityMap` with `money` set literally, **not** from a simulated city
  — a damaged producer yields fractional income (`1.0 * health / 100`), and an exact-equality
  assertion against a simulated balance would be checking float noise.
* **A refused place changes nothing** — both `money` and `nodes` asserted untouched. Asserting only
  the error tuple would pass a version that debits and *then* refuses.
* **A successful place debits exactly the type's cost** — the exact resulting balance, not merely
  "less than before".
* **Validation order, both clauses.** An occupied cell with an empty treasury returns `:occupied`;
  an unknown type with an empty treasury returns `:unknown_type` rather than raising out of
  `Map.fetch!`. Invisible in review, since every clause returns an error tuple.
* **The charge never enters demand.** After a place, `resource_stats(:money).demanded` reflects
  upkeep only — asserted positively as well (that `demanded` *does* track upkeep), so it cannot pass
  by reading zero out of a broken path.
* **`demolition_cost() < Enum.min(construction costs)`**, per §2.
* **Every `Node.types()` entry has a construction cost**, per §2.
* **A refused command broadcasts nothing.** `CityEngine`'s moduledoc already promises this, so
  `:insufficient_funds` must honour it — positive case (a successful place broadcasts both
  `{:city_node_placed, …}` and `{:city_metrics, …}`) asserted first.
* **`{:city_metrics, …}` after a place carries the post-debit balance**, so the treasury line moves
  on the click rather than on the next tick.

### Park

* **Net +6 at full health and −3 at zero.** Both, in one test or two — the zero-health case is the
  whole reason the income sits on the production side (§4), and without it `produce 6, consume 0`
  passes every other assertion.
* **Two parks on the bare baseline hold at full health; three decay.** The claim §4 makes about
  this not being a dominant opening, tested rather than asserted in prose.

### Presentation

* **The refused click sets an `:error` flash naming both figures**; a successful click sets none.
* **`data-affordable` is `"false"` for a type above the balance and `"true"` for one below it** —
  both directions, since a hardcoded `"false"` would satisfy either alone.
* **The treasury renders floored, not rounded.** A balance of 79.6 renders `79`, and with 79.6 in
  the treasury an 80-cost place is refused — asserted together, because the defect §5 describes is
  precisely the two disagreeing.
* **The cost column survives a collapse**, unlike the resource columns.

### Property

`place/4` either succeeds *and* debits exactly the cost, or fails *and* leaves the map identical —
never a partial outcome. Over generated node types and starting balances, via the existing
`test/support/city_generators.ex`. This is the invariant the individual cases above sample; as a
property it also covers the type/balance combinations nobody thought to enumerate.

### Not needed

No snapshot test beyond what exists. §3 establishes that no persisted field changes, so the
existing old-snapshot coverage is sufficient and a new fixture would assert nothing new.
