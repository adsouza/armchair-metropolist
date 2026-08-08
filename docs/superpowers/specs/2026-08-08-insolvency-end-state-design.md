# Insolvency: a city that can never pay for its own escape — design

**Date:** 2026-08-08
**Status:** designed, not yet implemented
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

### 3.3 `runway/1`

`trunc(money / drain)` where `drain = demanded - supplied`, and `nil` when not insolvent.

The division needs no guard, and the reason is structural rather than defensive: `supplied`
is a sum of health-scaled capacities and so never exceeds `money_ceiling`, and `insolvent`
means `money_ceiling < demanded`, so `drain > 0` strictly. Gating on `insolvent` is
therefore what makes the arithmetic safe *and* what makes the figure honest — a sick-but-
recovering shop also drains, and a countdown there would be a prediction the city disproves.

### 3.4 `escape/1`

The cheapest single action that would end the insolvency, derived from the tables. Returns
`{:place, type, cost}`, `{:demolish, type, cost}`, or `{:multiple, cheapest_action_cost}`.

Let `gap = demanded - money_ceiling` and `net(t) = capacity(t)[:money] - load(t)[:money]`.
Placing one `t` moves the gap by `-net(t)`; demolishing one moves it by `+net(t)`. So:

* candidate placements: every `t` with `net(t) >= gap`, at `Node.construction_cost(t)`
* candidate demolitions: every `t` with `by_type[t].count > 0` and `-net(t) >= gap`, at
  `Node.demolition_cost()`
* cheapest of those; `{:multiple, ...}` when the list is empty, so the copy can say honestly
  that one block will not be enough rather than naming an action that would not work

Measured nets: `commercial` +30 (cost 40), `residential` +1 (15), `power_plant` and
`industrial` 0, `park` −3 (20), `transit_hub` −4 (40), `water_plant` −5 (70).

A cost tie between the two families is unreachable and should not be coded around:
demolition is 10 and the cheapest construction is 15, and `node_test.exs` already pins that
ordering. Within placements a tie is unreachable too — the only types with positive net are
`commercial` at 40 and `residential` at 15 — so whatever `Enum.min_by/3` does with ties is
not load-bearing here. Do not write a test asserting a tie-break; it would pin behaviour no
input can produce.

### 3.5 `warning?/1`

`insolvent and not bankrupt and money < escape_cost + @reaction_ticks * drain`.

`not bankrupt` keeps the warning and the terminal state disjoint, so the banner has exactly
one variant to render at a time.

## 4. `@reaction_ticks`, and the test that pins it

`@reaction_ticks 12`. The warning band is 12 ticks wide by construction — the threshold is
the escape price plus 12 ticks of drain — which at the configured `tick_interval_ms: 1000`
is 12 seconds to read a banner and click once.

**A tick threshold alone would have been backwards.** Runway-in-ticks and can-I-afford-the-
rescue are on different scales. At stage 6 of the guide's opening sequence the city has only
a 20-tick runway but 180 in the bank against a 40-cost shop, so it is in no danger; the
softlock city has a 20-tick runway at 40 in the bank and is four placements from unreachable.
Pricing the escape is what separates them.

12 is a midpoint, not an edge. The binding constraint is stage 6 of the generated opening
sequence in `docs/PLAYING.md` — bank 180, escape a shop at 40, drain 9/tick:

| `@reaction_ticks` | threshold at stage 6 | slack vs bank 180 | warning the softlock city gets |
|---|---|---|---|
| 4 | 76 | 2.4× | 4 ticks |
| **12** | **148** | **1.22×** | **12 ticks** |
| 15 | 175 | 1.03× | 15 ticks |
| 16 | 184 | **fires during the guide's opening** | — |

Measured at 12, every stage of that sequence stays quiet:

| stage | gap | drain | escape | threshold | bank | verdict |
|---|---|---|---|---|---|---|
| 1 `residential` | — | — | — | — | 385 | solvent |
| 2 `park` | 2 | 2 | demolish park, 10 | 34 | 365 | quiet |
| 3 `water_plant` | 7 | 7 | place commercial, 40 | 124 | 295 | quiet |
| 4 `power_plant` | 7 | 7 | place commercial, 40 | 124 | 215 | quiet |
| 5 `residential` | 6 | 6 | place commercial, 40 | 112 | 200 | quiet |
| 6 `park` | 9 | 9 | place commercial, 40 | 148 | 180 | quiet |
| 7 `commercial` | — | — | — | — | 140 | solvent |

**The tripwire matters more than the value.** A test asserts that no stage of the opening
sequence warns, built from the same generator that writes that table into the guide, so a
balance patch which moves the sequence fails the build instead of quietly alarming players
mid-tutorial. Without it this constant is a hand-maintained mirror of figures that live
somewhere else, and it will drift.

## 5. Presentation

### 5.1 Metrics panel

One line, `<p id="metrics-runway">Runway: N ticks</p>`, rendered `:if={@metrics.insolvent}`,
placed after Treasury and before Landfill so the three money-adjacent figures read together.
Plain text, never styled as an alert — the same treatment as `metrics-tightest`, which is
also conditional and also a glance figure.

This is a **width-neutral** addition by inspection: it is shorter than `metrics-tightest`'s
longest rendering and far shorter than the totals footnote at 1288px that currently binds the
sidebar, so it cannot move the wrap thresholds documented in `render/1`. Confirm by
measurement before claiming it in a comment.

### 5.2 `collapse_banner/1`

The guard widens from `@metrics.stalled` to `@metrics.stalled or game_over?(@metrics) or
warning?(@metrics)`, and the copy grows from two variants to four. The two existing ones keep
their wording; both new ones state the mechanism, in the order the module already uses —
verdict first, mechanism under it.

* **insolvent and bankrupt** (error styling): "City locked — nothing more can be built or
  demolished." Then: upkeep per tick, the most the city can earn at full health
  (`money_ceiling`), the two prices, and that the treasury can therefore never reach 10
  again. Not "this city is dead" — a house at 100 health makes that sentence false, which is
  the reason this state has its own copy rather than reusing the game-over paragraph.
* **insolvent, not bankrupt, under threshold** (warning styling): "Upkeep outruns income — N
  ticks of treasury left." Then the escape from `escape/1`, named and priced.

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
| bank 34 → quiet, 33 → warn, 10 → warn, 9 → terminal | an off-by-one or a flipped comparator in the threshold |
| every generated opening stage → quiet | raising `@reaction_ticks` past 15 |
| runway with bank 20, drain 2 → 10 | swapping the division's operands |
| gap 2 with a park placed → `{:demolish, :park, 10.0}`; gap 7 → `{:place, :commercial, 40.0}` | returning `cheapest_action_cost` unconditionally |
| gap 40, only parks placed → `{:multiple, 10.0}` | naming a single action that would not close the gap |
| `show_reset?` true for house+park at bank 0, false for a fresh city | dropping the new disjunct |

Two constraints on fixtures, both from defects this repo has shipped:

* **Asymmetric values throughout.** A park at 3 against a water plant at 5, never two of a
  kind. A city whose money-consumers are uniform cannot distinguish `escape/1` picking the
  cheapest from it picking the first, and cannot distinguish the ceiling from the flow.
* **The 9/10 and 33/34 boundaries are asserted on both sides.** A one-sided assertion passes
  against a comparator that admits the whole half-line.

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
