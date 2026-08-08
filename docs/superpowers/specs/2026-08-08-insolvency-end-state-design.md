# Insolvency: a city that can never pay for its own escape — design

**Date:** 2026-08-08
**Status:** designed, revised after adversarial review, not yet implemented
**Revision:** an adversarial review found three defects in the first draft, all confirmed by
measurement and all fixed here rather than accepted. (1) `insolvent` and `stalled` are not
mutually exclusive, so the warning counted down a treasury the engine had already frozen —
§3.5, and the banner now uses an explicit precedence order in §5.2. (2) The escape could price a
placement onto a full grid, which `ManageInfrastructure.place/4` refuses — §3.4. (3) The warning
band was computed as `escape_cost + 12 × current_drain` and claimed to be 12 ticks wide "by
construction"; measured, a city with falling income got 4 — §3.3, now an exact forward
projection. The third is the one that mattered: the tripwire test the draft relied on used only
fully-supplied fixtures, which is precisely where the broken formula was correct.
**Discharges:** the "partial fixpoints are not detected" accepted consequence of
`2026-08-06-collapse-end-state-and-city-reset-design.md`, §8. That spec deferred the case on
two stated grounds — "the player can still act there, income is still arriving". Measured,
both are false across a reachable subset of it, and its own worked example is a member of
that subset. This design does not widen collapse detection to all partial fixpoints; it
carves out the subset where the justification does not hold and gives that subset an end
state of its own.

## 1. Problem

**The Reset button is unreachable from a city that is permanently locked but not dead.**

`SimulatorLive.show_reset?/1` is `not metrics.housing_alive and (metrics.node_count > 0 or
metrics.bankrupt)`. Living housing suppresses the button unconditionally; the treasury is
consulted only as a fallback for cities whose housing is *already* dead. So a city with one
healthy house and an empty treasury has no affordance at all — no button, and no banner
either, since `collapse_banner/1` renders only on `stalled`.

Measured 2026-08-08, one healthy house and one park, treasury at 0:

| | tick 0 | tick 2000 |
|---|---|---|
| nodes | house 100.0, park 100.0 | house **100.0**, park 0.0 |
| treasury | 0.0 | 0.0 |
| money | supplied 1.0 vs demanded 3.0 | supplied 1.0 vs demanded 3.0 |
| `avg_health` | 100.0 | 50.0 |
| `housing_alive` / `stalled` / `game_over?` | true / false / false | true / false / false |
| Reset button | hidden | **hidden** |

The house draws only power, water, waste and traffic, every one of which sits inside the
free baseline of 40, so it holds at 100 health forever and `housing_alive` never goes false.
The park's 3/tick money upkeep permanently outruns the house's 1/tick income, so
`new_balance/1` floors the treasury at 0 every tick. Nothing costs less than
`Node.cheapest_action_cost/0` (10). The player is a spectator, permanently.

The prior spec's own example behaves the same way. A live house beside a dead water plant,
treasury 0, after 2000 ticks: house 100.0, water plant 0.0, treasury 0.0, income 1.0/tick
against 5/tick of upkeep. Its two justifications, taken in turn:

* *"The player can still act there"* — false below 10. Both commands are refused, so the
  city is unreachable by any input.
* *"Income is still arriving"* — true, and irrelevant. 1.0/tick arrives and is destroyed by
  5/tick of upkeep before it can become a balance. Income arriving is not the same as a
  treasury rising, and only the second is what buys an escape.

### Why this is provable rather than merely likely

The asymmetry the whole simulation is built on — capacity is health-scaled, load never is
(`SimulationCalculator`, steps 1–2) — makes the terminal claim an argument rather than an
extrapolation from 2000 ticks:

1. Money demand is the sum of the load table over placed nodes, scaled by nothing. It is
   fixed while the set of nodes is fixed.
2. The set of nodes can change only by `place` or `demolish`, and both are refused while
   `money < cheapest_action_cost`.
3. Money supply is the sum of health-scaled capacity, so it never exceeds the **rated**
   ceiling: the same sum at full health.
4. Therefore if `rated_ceiling < demanded`, then `supplied < demanded` at every future tick,
   so `new_balance/1` is `max(0.0, supplied + carried - demanded) < carried` whenever
   `carried > 0` — strictly decreasing to 0, and pinned there.
5. So the treasury never reaches 10 again, and step 2 holds forever.

Call that condition **insolvent**. `docs/PLAYING.md` already uses the word in exactly this
sense at line 267: "a support set without a commercial block is insolvent — the treasury
drains over the game's lifetime even while every other resource reads 100% satisfied."

### Non-goals

* **No new resource, and no change to any capacity, load or cost table.** Nothing here
  changes what a tick computes.
* **No widening of `stalled`.** See §7.
* **No confirmation dialog on Reset.** Unchanged from the 2026-08-06 design, §7.
* **No detection of partial fixpoints in general.** A live house beside a dead water plant
  with 400 in the bank is still deliberately not an end state — the player can act, and the
  treasury is rising or holding. Only the insolvent subset is claimed.
* **No persisted flag.** `insolvent` is recomputed from the city on every hydration, like
  `bankrupt` and `stalled` before it.

## 2. The rated ceiling, not the current flow

This is the load-bearing choice in the design, so it is stated before the mechanics.

Three candidate gates were measured against five cities. The two obvious ones both fire on
cities that recover:

| gate | house+park, bank 0 (locks forever) | lone house, bank 0 | house + **sick** shop + park, bank 0 |
|---|---|---|---|
| `bankrupt` alone | fires ✓ | **fires ✗** — recovers to 200 | **fires ✗** — recovers to 11,200 |
| `bankrupt and supplied <= demanded` | fires ✓ | correct | **fires ✗** — recovers to 9,833 |
| `bankrupt and rated_ceiling < demanded` | fires ✓ | correct | correct |

The current-flow gate looks safer than bare bankruptcy and still condemns a city whose shop
is merely *sick*: income 2.5 against upkeep 3 today, 31 against 3 once it heals. Only the
ceiling comparison is both free of false positives and provable by the argument in §1.

## 3. Domain changes

All in `Domain.Entities.SimulationMetrics` unless stated. Nothing here is reachable from
`Infrastructure`, so nothing needs a new use case.

### 3.1 Two new fields

Added to the struct, the `@type t`, and computed in `build/3` beside `bankrupt`:

* `money_ceiling :: float()` — `by_type` summed over `rated_capacity[:money]`. A field rather
  than a call site derivation because the banner copy prints it, and a printed figure and a
  gate that disagree is the defect class `trunc/1` on the treasury exists to prevent.
* `insolvent :: boolean()` — `money_ceiling < resources[:money].demanded`.

Both derive from data `build/3` already has: `resources` is an argument and `by_type` is
built in the function. Neither joins the `derived` map, which carries only figures
`SimulationCalculator` must compute because `Domain.Entities` cannot.

`SimulationMetrics` is not persisted — only `CityMap` and `Node` are, and
`SnapshotVocabulary` covers those — so adding fields here is not a data migration.

### 3.2 `game_over?/1` widens

```
bankrupt and (stalled or insolvent)
```

One concept — "the treasury can never rise again" — reached two ways, neither of which
implies the other:

* `stalled` freezes health at 0, so income is frozen at 0. The rated ceiling can be far
  above upkeep the whole time; a dead shop is still rated +30.
* `insolvent` leaves the clock running with a house at 100 health, so `stalled` is false.

The existing moduledoc on `game_over?/1` argues for exactly two halves and must be rewritten
rather than extended — its sentence "a running city that is merely broke still earns" is the
premise this design refutes, and leaving it beside the new disjunct would leave the module
contradicting itself.

### 3.3 `rescue_window`, by projection rather than by division

**Superseded design, recorded because the reasoning is the point.** The first version of this
section computed `trunc(money / drain)` from the current drain, and §4 claimed the warning
band was "12 ticks wide by construction". Measured, on one house, one shop and eleven parks at
a treasury of 35: quiet at tick 0, warning at tick 1, escape unaffordable at **tick 5**.

Income is health-scaled and the parks' 198 water demand starves the shop, so income fell
31 → 24.9 while drain grew 2 → 8.07 over those five ticks. `cost + N × current_rate` buys N
ticks only where the rate is constant, and the rate was the one term guaranteed to move.

The replacement is exact rather than bounded: **project the city forward with
`advance_tick/1`** — the simulation is deterministic and pure, so "what will the treasury be
in 8 ticks if the player does nothing" has an exact answer, and doing nothing is precisely
what a countdown is predicting.

`rescue_window` is the number of ticks until `money < escape_cost`, or `nil` when that does
not happen inside `@runway_horizon` (60) ticks, or when the city is solvent or stalled.

Three properties make the projection sound:

* **`escape_cost` is constant across the projection.** It derives from `gap = demanded -
  money_ceiling`, and both terms are count-based rather than health-scaled, so neither moves
  while the node set is fixed — which it is, since the projection assumes no player action.
  There is no fixpoint to iterate to.
* **The projection must stop when the projected city stalls.** `CityEngine` runs no tick while
  stalled, so a projection that kept draining past that point would predict a fall the engine
  will never perform. This is the same defect as §3.5's, one step further out.
* **Cost is measured, not assumed.** A 13-tick projection costs 0.12 ms at 12 nodes, 0.57 ms
  at 50, 1.59 ms at 200 and 9.05 ms at a pathological 1200; a 60-tick one costs 0.46 / 2.1 /
  6.44 / 37.6 ms. Against a 1000 ms tick, and only computed while insolvent, the exact answer
  is cheaper than the error in the estimate was.

To avoid computing `resource_stats/1` twice per projected tick — once for the stall check and
once inside `advance_tick/1` — extract a private `advance_tick(city_map, stats)` and let
`advance_tick/1` delegate to it. The projection then computes stats once per step and uses it
for both.

Because the projection lives in `Domain.Services.SimulationCalculator` (the only module that
may call `advance_tick/1`), the whole solvency group is computed there and arrives through
`derived`, exactly as `stalled` and the three amenity figures already do. See §3.6.

### 3.4 `escape/1`

The cheapest single action that would end the insolvency, derived from the tables. Returns
`{:place, type, cost}`, `{:demolish, type, cost}`, or `{:multiple, cheapest_action_cost}`.

Let `gap = demanded - money_ceiling` and `net(t) = capacity(t)[:money] - load(t)[:money]`.
Placing one `t` moves the gap by `-net(t)`; demolishing one moves it by `+net(t)`. So:

* candidate placements: every `t` with `net(t) >= gap`, at `Node.construction_cost(t)` —
  **only when the grid has a free cell**
* candidate demolitions: every `t` with `count(t) > 0` and `-net(t) >= gap`, at
  `Node.demolition_cost()`
* cheapest of those; `{:multiple, ...}` when the list is empty, so the copy can say honestly
  that one block will not be enough rather than naming an action that would not work

**The free-cell condition is load-bearing, not defensive.** `ManageInfrastructure.place/4`
refuses every occupied coordinate, so on a full grid a priced `{:place, :commercial, 40.0}` is
an instruction the player cannot follow: the real route is a demolition *then* a construction,
which costs more and may already be unaffordable. Filtering on
`node_count < width * height` is what keeps `escape/1`'s contract — "the cheapest single action
that would end the insolvency" — true rather than nearly true. A full 1200-cell grid is
remote but not unreachable, and the cost of the guard is one comparison.

This is why the derivation takes `city_map` rather than only `by_type`: the free-cell count is
not derivable from the metrics struct, which carries no dimensions.

Measured nets: `commercial` +30 (cost 40), `residential` +1 (15), `power_plant` and
`industrial` 0, `park` −3 (20), `transit_hub` −4 (40), `water_plant` −5 (70).

A cost tie between the two families is unreachable and should not be coded around:
demolition is 10 and the cheapest construction is 15, and `node_test.exs` already pins that
ordering. Within placements a tie is unreachable too — the only types with positive net are
`commercial` at 40 and `residential` at 15 — so whatever `Enum.min_by/3` does with ties is
not load-bearing here. Do not write a test asserting a tie-break; it would pin behaviour no
input can produce.

### 3.5 `warning?/1`

`insolvent and not stalled and not bankrupt and rescue_window != nil and rescue_window <=
@reaction_ticks`.

**`not stalled` is required, and its absence was a real defect in the first draft.**
`insolvent` and `stalled` are not mutually exclusive: a single dead water plant has a money
ceiling of 0 against 5 of demand, so it is insolvent; with 50 in the bank it is not bankrupt;
and measured, the first draft's `warning?/1` returned `true` for it and the panel would have
counted down 10 ticks. `CityEngine` runs no tick while stalled, so that treasury sits at 50
forever and every number in that countdown is false. The existing stalled-but-solvent banner
already describes this city correctly — "the treasury still holds 50 — enough to demolish, and
demolishing sometimes restarts the clock" — so the fix is precedence, not new copy.

### 3.6 The solvency group, and where each piece lives

`SimulationCalculator.metrics/1` computes one `solvency` group and passes it through `derived`
alongside `stalled` and the amenity figures, for the same architectural reason those travel
that way: `Domain.Entities` has `deps: []` and cannot reach `Domain.Services`, and the
projection needs `advance_tick/1`.

| figure | computed in | why not in `build/3` |
|---|---|---|
| `money_ceiling` | calculator | grouped with the rest; it is the input to all three below |
| `insolvent` | calculator | derived from `money_ceiling` and money demand |
| `escape` | calculator | needs `city_map` dimensions for the free-cell test, and feeds the projection |
| `rescue_window` | calculator | needs `advance_tick/1` |

`SimulationMetrics` stores all four as fields and exposes `game_over?/1` and `warning?/1` over
them. Keeping the *predicates* in the entity is what stops the template and `docs/PLAYING.md`
composing the conditions differently, which is the reason `game_over?/1` exists at all.

## 4. `@reaction_ticks`, and the test that pins it

`@reaction_ticks 12`. The warning fires when the projection says the escape becomes
unaffordable within 12 ticks, which at the configured `tick_interval_ms: 1000` is at least 12
seconds to read a banner and click once.

"At least" is now literal rather than aspirational. Because `rescue_window` is projected with
the real tick function rather than extrapolated from the current drain, a city whose income is
collapsing gets its warning *earlier* in treasury terms, not later in time — which is the
whole correction described in §3.3.

**A tick threshold alone would have been backwards.** Runway-in-ticks and can-I-afford-the-
rescue are on different scales. At stage 6 of the guide's opening sequence the city has only
a 20-tick runway but 180 in the bank against a 40-cost shop, so it is in no danger; the
softlock city has a 20-tick runway at 40 in the bank and is four placements from unreachable.
Pricing the escape is what separates them.

12 is a midpoint, not an edge. The binding constraint is stage 6 of the generated opening
sequence in `docs/PLAYING.md`, where the treasury holds 180 against a 40-cost shop and drains
9/tick. Measured against the implemented projection, every stage of that sequence stays quiet,
and stage 6 is the closest call:

<!-- measured against the implementation; re-run test/docs figures after any balance patch -->

| stage | escape | bank | `rescue_window` | verdict |
|---|---|---|---|---|
| 1 `residential` | — | 385 | — | solvent |
| 2 `park` | demolish park, 10 | 365 | beyond horizon | quiet |
| 3 `water_plant` | place commercial, 40 | 295 | 37 | quiet |
| 4 `power_plant` | place commercial, 40 | 215 | 26 | quiet |
| 5 `residential` | place commercial, 40 | 200 | 27 | quiet |
| 6 `park` | place commercial, 40 | 180 | **16** | quiet |
| 7 `commercial` | — | 140 | — | solvent |

So `@reaction_ticks` may rise to 15 before stage 6 warns. 12 keeps four ticks of margin at the
tightest stage — the same 1.22× in treasury terms the earlier draft had, since at full health
the projection and the division agree; what changed is that the figure is now also right when
they do not.

**The tripwire matters more than the value.** A test asserts that no stage of the opening
sequence warns, built from the same generator that writes that table into the guide, so a
balance patch which moves the sequence fails the build instead of quietly alarming players
mid-tutorial.

**That tripwire is necessary but not sufficient, and the first draft treated it as sufficient.**
Every stage of the opening sequence is fully supplied, which is exactly the condition under
which the superseded division was correct — so the tripwire shared the bug's blind spot and
would have passed over it. It is paired with an adversarial fixture that *can* break the
assumption: one house, one shop and eleven parks, whose water shortage makes income fall while
the treasury drains. That fixture asserts the escape is still affordable for all
`@reaction_ticks` ticks after the warning first fires, which is the property the design
promises and the property the tutorial fixture cannot see.

## 5. Presentation

### 5.1 Metrics panel

One line, `<p id="metrics-rescue">Rescue window: N ticks</p>`, rendered when `insolvent and
not stalled` and the projection returned a figure, placed after Treasury and before Landfill so
the three money-adjacent figures read together. Plain text, never styled as an alert — the same
treatment as `metrics-tightest`, which is also conditional and also a glance figure.

**"Rescue window", not "Runway", and the rename is a correctness fix rather than a preference.**
The number counts ticks until the *escape* becomes unaffordable, not ticks until the treasury
empties. The two differ by `escape_price / drain` — 20 ticks for a 40-cost shop against a drain
of 2, but only 4 at stage 6 of the opening sequence, where the drain is 9. Either way "Runway"
would have been a wrong reading of a right number, and the size of the error is not a constant
that could be documented away.

`not stalled` gates this line for the same reason it gates `warning?/1` (§3.5): a stalled city
runs no ticks, so a countdown in ticks describes nothing.

This is a **width-neutral** addition by inspection: it is shorter than `metrics-tightest`'s
longest rendering and far shorter than the totals footnote at 1288px that currently binds the
sidebar, so it cannot move the wrap thresholds documented in `render/1`. Confirm by
measurement before claiming it in a comment.

### 5.2 `collapse_banner/1`

The guard widens from `@metrics.stalled` to `@metrics.stalled or game_over?(@metrics) or
warning?(@metrics)`, and the copy grows from two variants to four.

**The four variants are selected by an explicit total order, not by four independent `:if`s.**
The first draft asserted they were disjoint and they are not — a stalled city can also be
insolvent (§3.5). Rendering the first match of an ordered list makes that impossible to get
wrong, and makes the precedence reviewable:

| # | condition | styling | copy |
|---|---|---|---|
| 1 | `game_over?` **and** `stalled` | error | existing "Game over — this city is dead" |
| 2 | `game_over?` (so insolvent, not stalled) | error | new "City locked" |
| 3 | `stalled` | warning | existing "City stalled — nothing is changing on its own" |
| 4 | `warning?` | warning | new "Upkeep outruns income" |

Row 1 before row 2 because a stalled city genuinely *is* dead — every block on the floor — and
that copy is the more specific truth. Row 3 before row 4 for the reason in §3.5: the stalled
banner already describes a frozen treasury correctly, and the countdown would not.

The two new variants state the mechanism under the verdict, in the order the module already
uses:

* **row 2, insolvent and bankrupt:** "City locked — nothing more can be built or demolished."
  Then: upkeep per tick, the most the city can earn at full health (`money_ceiling`), the two
  prices, and that the treasury can therefore never reach 10 again. Not "this city is dead" — a
  house at 100 health makes that sentence false, which is the reason this state has its own copy
  rather than reusing the game-over paragraph.
* **row 4, insolvent and within the window:** "Upkeep outruns income — N ticks to act." Then the
  escape from `escape/1`, named and priced. For `{:multiple, _}` the copy must say that no
  single block closes the gap rather than naming an action that would not work.

Both predicates are called module-qualified, as `game_over?/1` already is — the template
`alias`es `SimulationMetrics` rather than importing it, so `warning?/1` needs no new
directive but does need the prefix.

### 5.3 `show_reset?/1`

Gains `or SimulationMetrics.game_over?(metrics)`.

Today `game_over?` is a strict subset of `show_reset?` — `stalled` implies every node at 0
health, hence `not housing_alive`, and its `[]` clause means `node_count > 0`. Widening
`game_over?` breaks that containment, which is precisely the fix. **The comment above
`collapse_banner/1` asserts that containment** as its reason for naming the header button
rather than rendering a second copy of it. That reasoning survives the change only because
the new disjunct is added to `show_reset?` in the same edit; the comment must be rewritten to
say so, since as written it justifies the guarantee from a premise that is no longer true.

## 6. Tests

Named by the mutation each must kill, because a test that cannot fail is the recurring defect
in this repo's history.

| test | mutation it kills |
|---|---|
| house + park, bank 0 → `game_over?` true | reverting `game_over?` to `stalled and bankrupt` |
| dead shop + dead park, stalled, bank 0 → `game_over?` true | replacing the new `or` with `and` |
| live house + dead water plant, bank 0 → `game_over?` true | the 2026-08-06 non-goal returning |
| lone house, bank 0 → `insolvent` false | comparing current flow instead of the rated ceiling |
| house + **sick** shop + park, bank 0 → no warning, no Reset | the same, and the case the flow gate got wrong |
| `rescue_window` boundary asserted on both sides of `@reaction_ticks` | an off-by-one or a flipped comparator |
| every generated opening stage → quiet | raising `@reaction_ticks` past 15 |
| **1 house + 1 shop + 11 parks: escape still affordable for all 12 ticks after the warning fires** | **reverting `rescue_window` to `money / drain`** |
| dead water plant, bank 50: stalled, insolvent, not bankrupt → no warning, no rescue line | dropping `not stalled` from `warning?/1` |
| a city that stalls mid-projection → `rescue_window` nil, not a drained figure | projecting past the engine's tick-skip |
| full grid, gap 2, a park placed → `{:demolish, :park, 10.0}`, never `{:place, …}` | dropping the free-cell filter |
| gap 2 with a park placed → `{:demolish, :park, 10.0}`; gap 7 → `{:place, :commercial, 40.0}` | returning `cheapest_action_cost` unconditionally |
| gap 40, only parks placed → `{:multiple, 10.0}` | naming a single action that would not close the gap |
| `show_reset?` true for house+park at bank 0, false for a fresh city | dropping the new disjunct |
| banner precedence: stalled+insolvent+bankrupt → the *dead* copy, not the *locked* copy | reordering the four variants |

Three constraints on fixtures, all from defects this repo has shipped:

* **Asymmetric values throughout.** A park at 3 against a water plant at 5, never two of a
  kind. A city whose money-consumers are uniform cannot distinguish `escape/1` picking the
  cheapest from it picking the first, and cannot distinguish the ceiling from the flow.
* **Every boundary asserted on both sides.** A one-sided assertion passes against a comparator
  that admits the whole half-line.
* **At least one fixture whose income is falling.** Every fully-supplied fixture agrees with the
  superseded division, so a suite built only from those cannot fail when the projection is
  replaced by it. This is the constraint the first draft's tripwire violated, and it is the
  reason the eleven-park city is in the table above rather than in a comment.

`money_ceiling` needs its own characterization against the capacity table, for the reason the
comment on `bankrupt` already gives about `cheapest_action_cost/0`: no test inside the metrics
module can tell a real sum from a hardcoded copy of today's value.

## 7. Accepted consequences

**The engine still ticks a locked city forever.** `stalled` is false — the house is at 100
health — so `CityEngine` runs a tick a second on a city that can never change by any route.
Widening `stalled` to cover it was considered and rejected: `stalled` has a precise measured
meaning ("every block on the floor and still short of something, and the landfill not
draining") which five sections of `docs/PLAYING.md` describe and several tests pin, and the
freeze it drives is what makes a stalled city's treasury survive. Making the *engine's*
tick-skip read `stalled or game_over?` is the smaller version of that change and is still out
of scope here, because freezing an insolvent city changes what its landfill does. Flagged, not
fixed.

**The warning can fire on a city the player intended to run at a loss.** A player deliberately
banking a large treasury and spending it down through a long insolvent build-out gets the
banner in the last 12 ticks of it. The threshold prices the escape, so this only happens when
the rescue itself is nearly unaffordable, at which point the warning is correct even if it is
unwelcome.

**`rescue_window` is silent beyond `@runway_horizon`.** An insolvent city 200 ticks from trouble
shows no figure at all rather than "200 ticks", because the projection stops at 60. That is a
deliberate cost bound (§3.3) and it costs the player nothing: the interesting range is the one
where acting matters. It does mean the metrics line appears part-way through a long decline
rather than at its start, so the line is not the continuous-awareness display a division-based
figure would have been. Accepted as the price of the figure being true.

**The projection assumes the player does nothing.** That is the right semantics for a countdown
and the wrong semantics for a plan: a player mid-build who is about to place the shop sees a
window computed as though they will not. Unavoidable without predicting intent, and the copy
names the escape precisely so the prediction is easy to invalidate.

**`escape/1` considers single actions only.** For a gap wider than 30 no single action closes
it and the return is `{:multiple, 10.0}`, which prices *starting* rather than finishing. The
copy has to say so. A search over combinations would give a true total and is not worth its
complexity for a figure that changes every tick.

**A misclick on Reset now reaches a city with a healthy house in it.** The 2026-08-06 design
accepted misclick risk on the grounds that the button is "hidden entirely while any housing is
alive". That mitigation is exactly what this change removes for insolvent cities. The
narrowness of the gate is the replacement: the city is provably unreachable by any input, so
there is nothing left to destroy. Worth stating plainly because it is a real weakening of a
previously recorded safeguard.

## 8. Documentation

`docs/PLAYING.md`:

* **Line 455, "Game over"** — currently "the city has stalled *and* holds less than 10" and
  "because the clock has stopped, the balance will never rise again". Both are false for the
  insolvent route, where the clock runs. Rewrite around the shared property, "the treasury can
  never rise again", with the two routes to it.
* **Line 460, "Both states put a **Reset** button"** — three states now.
* **Line 267** already introduces *insolvent* correctly and needs no change, but should be
  cross-referenced from the new material so the word has one definition.
* **The "Running out of money" section** ends on "the escape has to be bought while there is
  still something to buy it with", which is now a mechanic with a warning attached rather
  than only advice. It should name the banner and the Runway line.
* A worked example of the softlock, with the measured figures from §1.

`docs/superpowers/2026-07-30-follow-ups.md`: record the engine-still-ticks consequence from
§7 so it is not rediscovered from the code.
