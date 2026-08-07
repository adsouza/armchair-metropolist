# Negative resource polarity: waste and traffic rise instead of dropping — design

**Date:** 2026-08-07
**Status:** designed, not yet implemented
**Ships as:** two commits on one branch. This document specifies the first; §9 records the second.

## 1. Problem

`docs/PLAYING.md` contains a reading instruction:

> Read `waste` and `traffic` as *capacity*: `industrial` supplies waste processing and
> `transit_hub` supplies transit capacity, which residential and commercial then consume.

A document telling the reader to reinterpret a term is naming a bug in the vocabulary. Waste is
the one resource a player arrives with a prior about — it is a *bad*, it accumulates, and you
build things to get rid of it — and the legend shows `industrial` supplying `+90` of it. The
model is not wrong. Its labels are inverted.

Two resources are affected, and they have the identical shape:

| resource | the health-scaled side | the unscaled side |
|---|---|---|
| `waste` | `industrial` 90, `park` 8 — *processing capacity* | five types emit 2–14 |
| `traffic` | `transit_hub` 60 — *road capacity* | six types draw 2–9 |

### The arithmetic is already the dual of the intended model

`satisfaction(r) = min(1.0, available / demand)`. For waste that is already
`min(1.0, capacity / load)`, health already decays exactly when the city generates more waste
than it can process, and `stats.deficit` is already the quantity of unprocessed waste.
**Nothing about the simulation needs to change.**

### The numbers must not move between tables

The obvious "fix" — make `industrial` *reduce* waste by moving its `90.0` into
`@consumption_table` — is wrong, and it is wrong in a way that no test in the suite would
catch as a design error.

Production is health-scaled (`Node.effective_production/1`); consumption is never scaled
(`SimulationCalculator.total_demand/1`). That asymmetry is the entire cascade mechanism, and
it is **already correct for waste**: a neglected incinerator processes less, a decaying house
still emits full. Moving industrial's `90.0` to the consumption side would unscale removal
from health, and a dead incinerator would process waste perfectly — making `waste` the one
resource neglect cannot punish. This is the same failure mode as
`2026-08-05-park-amenity-design.md` §3, where staffing `park` was what finally gave neglect
teeth there.

So the change is a **labelling and presentation** change. Polarity is a sign convention, and
sign conventions live where `signed/1` already lives.

### Non-goals

* **No accumulation.** Unprocessed waste stays a per-tick flow, not a carryover stock. A
  waste treasury like money's — but harmful — would create positive feedback and break
  `stalled?/2`, whose fixpoint argument depends on demand not moving between ticks
  (`simulation_calculator.ex:296`). Deliberately deferred; see §10.
* **No change to any table value.** Every measured figure in `docs/PLAYING.md` stays
  numerically valid. Only labels and signs move.
* **No new resource.** The six-resource vocabulary is unchanged.
* **No rebalancing.** Nothing about optimal play changes, because nothing about the
  simulation changes.
* **No rename of `production/1` and `consumption/1`.** That is the second commit, §9.

## 2. The polarity rule

A resource is **negative** when a rising figure is bad. For a negative resource the displayed
sign is inverted: a positive number means the type *adds to the problem*.

```
displayed net  =  produced − consumed      for a positive resource
displayed net  =  consumed − produced      for a negative resource
```

| type | waste today | waste after | traffic today | traffic after |
|---|---|---|---|---|
| `industrial` | +90 | **−90** | −8 | **+8** |
| `park` | +8 | **−8** | −2 | **+2** |
| `transit_hub` | −2 | **+2** | +60 | **−60** |
| `residential` | −10 | **+10** | −6 | **+6** |
| `commercial` | −14 | **+14** | −9 | **+9** |
| `power_plant` | −12 | **+12** | −3 | **+3** |
| `water_plant` | −6 | **+6** | −2 | **+2** |

The free baseline of 40 becomes free *absorption* capacity: a city with nothing placed can
handle 40 waste and 40 traffic before anything suffers.

**No type both produces and consumes waste, and none does for traffic.** This matters for §4:
it means the majority rendering path for a negative resource is `total_cell/4`'s
`is_nil(produced)` branch, which is the branch easiest to miss.

## 3. Domain — `Node`

The vocabulary is domain knowledge, alongside `resources/0` and `statuses/0`. The sign
convention is not.

```elixir
# Resources where a rising figure is bad. For these, a production-table entry is *removal*
# capacity and a consumption-table entry is *emission* — `industrial` processes 90 waste,
# a house emits 10.
#
# The numbers stay in the tables they are in today, and must. Production is health-scaled
# and consumption never is, which is exactly the right asymmetry here: a neglected
# incinerator processes less, a decaying house still emits full. Moving industrial's 90 to
# the consumption table to make it "read as removal" would unscale removal from health, and
# waste would become the one resource neglect cannot punish.
#
# Written out rather than derived, for the same reason `@resources` is: this is a design
# commitment, and a derivation would let a table edit silently change which resources are
# bads.
@negative_resources [:waste, :traffic]

@spec negative_resources() :: [resource()]
def negative_resources, do: @negative_resources

@spec negative_resource?(resource()) :: boolean()
def negative_resource?(resource), do: resource in @negative_resources
```

**No snapshot work.** The persisted `Node` struct is `[:id, :x, :y, :type, :health, :status]`
and `SnapshotVocabulary`'s reachable-struct set is `CityMap` and `Node`. Resource atoms never
reach a stored term, so unlike the `road_hub` → `transit_hub` rename this is not a data
migration and no `@node_type_renames` entry applies.

## 4. Web — the sign convention in one function

`SimulationCalculator` and `SimulationMetrics` are **untouched by this commit** — §9 renames
fields in the latter. `build_by_type/1` scales the tables and never interprets them, so
polarity stops at the view boundary.

Four rendering sites read the same tables. They get **one** shared helper rather than four
independent flips — this legend has already shipped a defect where `marginal_cell/3` was
patched and `total_cell/4` was not, leaving a bold `−3` in the more prominent position where
`+12` was true (`2026-08-05-park-amenity-design.md` §5):

```elixir
# The sign convention, in one place. For a negative resource a positive figure means the type
# adds to the problem: `industrial` reads −90 because it removes 90 waste, a house reads +10
# because it emits 10.
#
# One function rather than a flip at each call site, deliberately. `marginal_cell/3` and both
# branches of `total_cell/4` read the same two tables, and the `is_nil(produced)` branch is the
# one that fires for most types on a negative resource (§2) — so a partial patch would leave
# every emitter rendering backwards while the two removers looked right.
defp net(resource, produced, consumed) do
  if Node.negative_resource?(resource),
    do: consumed - produced,
    else: produced - consumed
end
```

Applied at:

| site | before | after |
|---|---|---|
| `marginal_cell/3` general clause | `signed((produced \|\| 0.0) - (consumed \|\| 0.0))` | `signed(net(resource, produced \|\| 0.0, consumed \|\| 0.0))` |
| `total_cell/4` `is_nil(produced)` | `signed(-consumed)` | `signed(net(resource, 0.0, consumed))` |
| `total_cell/4` main branch | `produced - (consumed \|\| 0.0)` for both nets | `net(resource, produced, consumed \|\| 0.0)` and the same for `actual` |

The `{:park, :labour}` clauses are labour-only — labour is positive — and are untouched.

**The rated→actual arrow survives and improves.** A half-dead `industrial` renders
`−90 → −45`: removal is health-scaled, so the arrow now shows disposal capacity failing, which
is the cascade made visible. A decaying house shows no arrow on waste, correctly — emission is
not health-scaled.

### The totals footer

`totals_cell/2` is a pair rather than a net, so it takes the ordering swap instead — and
becomes polarity-free, because **both** orderings unify on draw-against-capacity:

```elixir
"#{round(stats.demanded)}/#{round(stats.supplied)} · " <>
  "#{Float.round(stats.flow_satisfaction * 100, 1)}%"
```

Header (`simulator_live.ex:592`) becomes **`demanded/supplied · met this tick`**.

This is the convention `docs/PLAYING.md` already uses for its `tightest resource` column —
"demand against supply, so `40/40` is at capacity and not over it" — so the guide and the app
stop disagreeing about column order. `flow_satisfaction` stays derivable from the two numbers
shown, in either order.

The `colspan="3"` and the untestable-by-construction warning above it are unaffected.

**`metrics/1` and `tightest_resource/1` need no change.** Both read `satisfaction`, which is
polarity-agnostic; "Tightest: waste 87%" still means waste is the binding constraint.

### The footnote is a measured width and rewording it is not free

`simulator_live.ex:617` reads "Totals include the free baseline of 40 for power, water, waste
and traffic". For waste and traffic that baseline is now free *absorption*, so the sentence
must change — and this paragraph is, measured 2026-08-06, the **binding width of the expanded
sidebar** at 1198px, wider than the nine-column matrix's 927px. It is what sets
`max-[2335px]:flex-row`.

So the reword must either stay at or below 1198px of max-content, or `max-[2335px]` needs
re-measuring against the new text. Measure it; do not reason about it. The collapsed
threshold `max-[1415px]` is set by the 359px re-entry line and is not at risk.

## 5. Documentation

**The payoff is deleting the reading instruction at `docs/PLAYING.md:469-470` outright.** That
sentence is the artefact this change exists to remove.

### The two generated reference tables need polarity, and a heading change

`PlayingGuide.production_block/0` and `consumption_block/0` render from `Node`'s tables. Left
alone they would publish `industrial | waste 90` while the app shows `−90`. Rendering the sign
is not enough on its own, because "What each type **produces**" is exactly the wrong verb for a
row reading `waste −90`.

The headings become the distinction that is actually load-bearing:

| before | after |
|---|---|
| "What each type produces" — *Production is scaled by the node's health* | **"Per-block effect, scaled by health"** |
| "What each type consumes" — *Consumption is **never** scaled by health* | **"Per-block effect, never scaled by health"** |

Every cell signed per §2. The pedagogy survives intact — the health-scaling asymmetry is now
in the heading rather than the caption, which is a promotion — and no reading instruction is
needed, because a signed cell under a neutral heading is true for both polarities.

The `baseline`, `constants`, `capacities`, `costs`, `opening`, `opening_pace` and
`opening_wall` blocks are unaffected: none of them renders a per-type ledger sign. The
`opening` block's `tightest resource` column already reads demand-against-supply.

`PlayingGuide` carries its own hand-copied `@resources` list. Out of scope here, but noted —
it is a mirror of `Node.resources/0` that nothing forces to stay in step.

### Prose

| location | change |
|---|---|
| `PLAYING.md:469-470` | **delete** — this is the point |
| `PLAYING.md:92` | free baseline: 40 each, absorption for waste and traffic |
| `PLAYING.md:267` | "its falling waste output drags the rest of the city" → falling waste *processing*. Still a mechanism claim, still true, inverted wording |
| `PLAYING.md:175, 265, 286, 323, 341` | re-read each; several name waste in a list of resources and need no edit |
| `README.md:7` | "as supply against demand" — reword for both polarities |

Per `mechanism-prose-survives-classification-prose-does-not`: the sentences at risk here are
the ones handing out a verdict about waste, not the ones describing how it flows. Audit each
hit rather than pattern-replacing.

## 6. Rejected alternatives

**Swap the table entries.** Move `industrial`'s waste to `@consumption_table` and
`residential`'s to `@production_table`, so the code literally says industrial removes waste.
Rejected in §1: it unscales removal from health and kills the cascade for waste. It also
inverts the health signal unless `satisfaction/2` is inverted to match, so it is strictly more
work for a worse result.

**Rename the resource.** `:waste` → `:sanitation`, `:traffic` → `:transit`. Makes the current
tables honest with a two-atom change and no display work at all. Rejected because it solves the
developer's problem by abandoning the player's: nobody wants a city that maximises sanitation,
and "waste" is the word carrying the intuition worth having.

**Flip waste only, leave traffic.** Rejected: `traffic` has the identical shape, so the guide
would still need a reading instruction — for one resource instead of two — and the legend would
carry two conventions side by side. A one-element `@negative_resources` also invites the
mechanism being written as a waste special-case.

**Put polarity in the domain**, returning pre-signed figures from `SimulationMetrics`.
Rejected: `by_type` figures feed the guide generator and the tests as well as the legend, and a
pre-signed domain would force every consumer to know the convention. Signs are presentation;
`signed/1` already establishes where that lives.

## 7. Accepted consequences

**Two sign conventions coexist on one screen.** Power reads `+120` for a good thing; waste
reads `−90` for a good thing. This is inherent to the request and is how any pollutant is
scored — you want net emissions negative — but it is a real thing a player must absorb. The
column header and the guide's per-block table are what carry it.

**"Tightest" is a slightly odd word for a pollutant.** "Tightest: waste 87%" means waste is the
binding constraint, which is true and useful. Left alone rather than special-cased; a
polarity-dependent label would put a second convention into a line whose whole job is to be
glanceable.

**`stats.deficit` for waste is unprocessed waste, and nothing renders it.** It is the number
most directly matching "waste that has built up", and it already exists. Deliberately *not*
surfaced as a new metrics line: the totals row shows `52/56` and the Tightest line names the
resource, so a third view of the same fact is noise. Recorded so it is a considered omission
rather than an oversight — and so that if §10's accumulation work happens, this is the field it
builds on.

**Every measured figure in the guide stays valid**, because no table value moves. This is the
strongest property of the design and the reason the estimate is a day.

## 8. Testing

Two rules from the follow-ups doc apply: **no `refute` without the positive case asserted
first**, and **a test you have not seen fail is not yet a test**. Each test below names the
mutation it must catch, because on this project the recurring finding is a test that cannot
fail rather than an implementation that is wrong.

### `node_test.exs`

* **`negative_resources/0` is a subset of `resources/0`.** Kills a typo'd atom that would
  silently never match.
* **It is exactly `[:waste, :traffic]`, and `power`/`water`/`labour`/`money` are not
  negative.** Both halves. This is a design commitment, and pinning it means a seventh
  resource forces a polarity decision instead of defaulting to positive in silence.

### `simulator_live_test.exs` — the flip

* **`data-cell="industrial-waste"` renders `−90` and `data-cell="residential-waste"` renders
  `+10`, in one test.** Catches a flip applied in the wrong direction, which a single-cell
  assertion cannot see: negating everything satisfies either assertion alone.
* **A positive resource in the same assertion** — `power_plant-power` still `+120`. Catches a
  flip applied to every resource rather than the negative ones.
* **`transit_hub-traffic` renders `−60` and `residential-traffic` renders `+6`.** Traffic is
  not a copy of waste in the code, but it is in the tables; asserting it stops
  `@negative_resources` shipping as `[:waste]`.
* **Both lines of one cell.** Assert the marginal line *and* the `.font-semibold` total line
  separately, as the park amenity tests learned to: the cell's text contains both figures, so a
  cell-level assertion silently matches whichever line the flip reached. `residential-waste`
  is the case that matters — it takes `total_cell/4`'s `is_nil(produced)` branch, which is the
  branch §2 shows fires for most types.

### `simulator_live_test.exs` — the totals row

* **`data-total="waste"` renders `52/56`, not `56/52`.** Requires a fixture where supplied ≠
  demanded; at `56/56` the ordering assertion cannot fail at all
  (`fixture-values-must-discriminate`).
* **`data-total="power"` in the same fixture**, also with supplied ≠ demanded, and also
  demand-first. Catches an ordering swap applied only to negative resources — the mistake the
  §4 unification exists to prevent.
* **The header reads `demanded/supplied`.** A string assertion, but the ordering is a decision
  and a silent revert should redden something.

### `simulator_live_test.exs` — the arrow

* **A degraded `industrial` renders `−90 → −45`.** Pins that removal is still health-scaled
  after the flip, and that both nets are flipped rather than just the rated one — the mutation
  flipping only `rated_net` yields `−90 → +45`, which no single-figure assertion catches.

### `playing_guide_test.exs`

* **Regenerated blocks match**, with `REGENERATE_PLAYING_GUIDE=1`. The `production` and
  `consumption` blocks change; the other seven must not. Assert the unchanged ones stay byte-
  identical rather than accepting whatever regeneration emits — an identical pass count is the
  weakest evidence available (`green-suite-hides-changed-fixtures`).
* **The guide no longer contains "as *capacity*".** The deletion in §5 is the deliverable; a
  test is what stops it being reintroduced by a future edit that finds the tables confusing.

### Not needed

No snapshot test. §3 establishes that no persisted term changes shape and no atom enters one.
No `SimulationCalculator` test changes: its arithmetic is untouched, and a change there would
mean the design was violated.

## 9. The second commit: `production`/`consumption` → `capacity`/`load`

Approved as a follow-up on the same branch, landing after the above.

After this change the domain still reads `@production_table %{industrial: %{waste: 90.0}}`
with a comment explaining that it means removal — which is the same reading-instruction smell
§1 exists to delete, relocated from the guide into the code. The honest fix is renaming to
terms true of both polarities: `capacity` (the health-scaled side) and `load` (the unscaled
side). For power, `power_plant` has capacity 120 and a house has load 15; for waste,
`industrial` has capacity 90 and a house has load 10. No reinterpretation needed either way.

Kept separate because the blast radius roughly doubles and is mechanical rather than
interesting: `Node.production/1` and `consumption/1`, `SimulationMetrics.type_stats`'s
`rated_production` / `actual_production` / `consumption` field names — which the legend
destructures — plus every test, `PlayingGuide`, and the guide headings §5 already touches.
Landing it separately keeps the polarity change reviewable on its own.

## 10. Deferred: waste as an accumulating stock

Considered and explicitly deferred. Making unprocessed waste carry over — a `@carryover` entry
like money's, but harmful, adding to the next tick's load — is what the word "accumulates"
usually implies, and it is a genuine mechanics change rather than a labelling one:

* It creates **positive feedback**. Money's carryover is stabilising; waste's would be a doom
  spiral, and the decay rate was measured without one.
* It **breaks `stalled?/2`**. That function's fixpoint argument is that demand does not move
  because demand is not health-scaled (`simulation_calculator.ex:296`). Accumulating waste
  makes demand move between ticks, so the reasoning behind the collapse end-state and
  `game_over?/1` would need redoing.
* It **invalidates the guide's measured figures**, including the opening sequence, its pacing
  bound, and the capacities block — the opposite of §7's strongest property.

Revisit once the polarity change has been played with. §7 records that `stats.deficit` is the
field it would build on.
