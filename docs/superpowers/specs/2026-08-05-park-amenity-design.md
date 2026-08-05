# Park amenity and staffing: parks multiply the labour their housing supplies, and both parks and transit hubs draw it — design

**Date:** 2026-08-05
**Status:** designed, not yet implemented
**Ships before:** `2026-08-05-construction-costs-design.md`, which prices `park` and needs it to be
worth buying first

**Amended 2026-08-05, before implementation**, to add staffing for `transit_hub` and `park` (§3). The
two changes cannot ship separately: staffing `park` drops its net labour contribution to `4k − 1`, and
at the originally specified `k = 0.5` that is +1, which measurement shows changes nothing. Releasing
the amenity alone and adding staffing afterwards would ship a mechanic that is provably a no-op in
between. `k` is therefore 1.0, not 0.5.

## 1. Problem

Two problems, and they are solved by the same design because each supplies what the other needs.

**`park` has no reason to exist.** `docs/PLAYING.md` says so directly — "usually a trap — it trades a
lot of water for a little waste capacity, so it only pays when you have spare water and are
waste-limited, which is rare given how much `industrial` supplies." Measured, searching every stable
solvent city under a 900 build budget for maximum income, the optimum contains exactly **one** park.
It is worth almost exactly one tile and no more. That is tolerable while placement is free and stops
being tolerable once construction costs land, because then it is a type you pay 20 for and would
never want.

**Nothing that is obviously staffed draws labour except industry and commerce.** A transit hub runs
without a single member of staff, and a park maintains itself. Labour is currently a tax on exactly
two types.

**And `park` has no downside when neglected.** Every other type punishes neglect, because production
is health-scaled while consumption is not — a dying node keeps drawing its full demand. A park's only
output is 8 waste, so letting one rot costs almost nothing.

### Non-goals

* **No new resource.** The six-resource vocabulary is unchanged.
* **No staffing for `power_plant` or `water_plant`.** They stay automated. This matters for the
  reversal §3 records: labour must not become universal.
* **No change to `park`'s water, traffic or money consumption.** Water 18 in particular stays —
  thirst is `park`'s character and, as §4 shows, the constraint that actually bounds it.
* **No adjacency or service radius.** `docs/PLAYING.md` records that position does not matter
  anywhere in this engine, and a park that cared about distance would be the first exception.
* **No amenity effect on any resource but labour.**
* **No re-pricing of `park`.** Its construction cost is the other spec's business.

## 2. The amenity rule

Total labour supply is multiplied by a factor derived from how much park there is *per housing block*:

```
housing  = Σ residential health / 100          # effective housing
parks    = Σ park        health / 100          # effective parks

amenity  = 1 + k × min(parks / housing, cap)   when housing > 0
amenity  = 1                                   when housing = 0

labour_supply = (baseline + Σ health-scaled labour production) × amenity
```

with

```elixir
@amenity_per_housing 1.0   # k
@max_amenity_ratio   1.0   # cap: one park per housing block is full provision
```

The multiplier runs from ×1.0 to a maximum of **×2.0**, reached when parks equal housing.

**Both sides are health-weighted, not counted.** A neglected park provides no amenity, and a dying
neighbourhood needs fewer parks to serve it. This follows the same rule as every other benefit here:
a count-based ratio would let a dead park go on multiplying, making `park` the one type neglect
cannot punish.

### The algebra that makes this work

With `H` housing and `P` parks, below the cap:

```
labour_supply = 4H × (1 + kP/H) = 4H + 4kP
```

The ratio multiplier **collapses to a constant gross bonus of `4k` per park** — with `k = 1.0`,
exactly **+4 labour per healthy park**, independent of city size. Verified numerically at
`(H,P) = (6,6), (6,3), (12,4), (10,10)`: every case matches `4H + 4kP` to floating-point equality.

Net of the park's own 1 labour (§3), a healthy park below the cap is worth **+3 labour**.

Three consequences, and they are why this shape was chosen over the alternatives in §7:

1. **It behaves like an additive bonus**, so balance measured on the additive form transfers.
2. **It is zero when there is no housing.** `0 × anything = 0`. A city of parks and shops with nobody
   living anywhere cannot staff itself — which an additive labour term cannot express.
3. **The legend can show a fixed number**, because the marginal effect does not depend on city size.

## 3. Staffing

Two consumption tables gain a labour entry. Nothing else about them changes.

| type | labour | rationale |
|---|---|---|
| `transit_hub` | **2.0** | Stations and services are staffed. Small against `industrial`'s 12 |
| `park` | **1.0** | Grounds need keeping. The smallest whole number that has any effect |

**`transit_hub` at 2.0 rather than 3.0 is free.** Measured at budgets 900 and 2000, the optimal city
is identical at either value, so the change takes the lower end and disturbs the documented
equilibrium less.

**`park` at 1.0 is not free — it forces `k`.** Park's net contribution is `4k − 1`, so at the
originally specced `k = 0.5` the net is +1, and the amenity becomes a total no-op: measured under
staffing at budget 900, `k` at 0.0, 0.25 and 0.5 all produce the *same* optimum (income 48, 2 parks,
8 residential). §4 records the search that sets `k = 1.0`.

**Staffing is what gives `park` teeth on the downside.** The amenity is health-weighted; consumption
never is. So a park at zero health provides **no** amenity while still drawing its full 1 labour, 18
water and 3 money — a pure drain. Before this, neglecting a park cost 8 waste capacity and nothing
else. This is the asymmetry the engine is built on, finally applying to `park`.

**It also makes the ratio cap nearly redundant** (§4): a staffed park limits its own usefulness, so
water and build cost bind before the ratio does in any ordinary city.

### This reverses half of a documented decision

The money-and-labour design (2026-08-02) listed as an explicit non-goal: "No labour requirement on
`power_plant`, `water_plant`, `transit_hub` or `park`. Staffing every type would make labour a
near-universal tax and flatten the distinction being drawn."

Two of those four are now staffed. The reasoning that survives: `power_plant`, `water_plant` and
`residential` still draw no labour, so **four of seven types** consume it and the tax is not
universal. The distinction is narrower than it was, and deliberately so — the original line drew
"industry and commerce are staffed, infrastructure is not", and the new line draws "utilities are
automated, everything people use is staffed", which is the more defensible cut. Recorded rather than
glossed, because a reader of that spec will otherwise find it contradicted with no explanation.

## 4. Why these constants

Settled by search, not argument. The search enumerates every combination of the seven types within
stated bounds, keeps those where all six resources are satisfied at full health and money does not run
a long-run deficit, and reports the highest-income city within a build budget.

### `k`, with staffing held fixed at transit 2 / park 1, budget 900

| k | best income | parks | residential | multiplier |
|---|---|---|---|---|
| 0.0 | 48 | 2 | 8 | ×1.0 |
| 0.25 | 48 | 2 | 8 | — |
| 0.5 | 48 | 2 | 8 | — |
| 0.75 | 50 | 1 | 7 | — |
| **1.0** | **62** | **5** | **6** | **×1.83** |
| 2.0 | 99 | 4 | 5 | ×2.6 |

**`k = 1.0` is the smallest value that does real work.** Below it the amenity is indistinguishable
from absent — 0.0, 0.25 and 0.5 give byte-identical optima. `k = 0.75`, which would hold park's net at
+2, is measured *worse for park* than 0.5: the optimiser takes one park and a cheaper shape.

So the staffing tax shifts the whole usable band upward. The unstaffed additive experiment found net
+2 per park to be the sweet spot and net +3 to start eroding housing; under staffing, net +2 is
unreachable without the mechanic collapsing, and net +3 (`k = 1.0`) is the working value. §6 records
the erosion that comes with it.

**`k = 2.0` overshoots.** Income 99 is a large jump, but residential falls to 5 and the multiplier
reaches ×2.6 — each home fielding more than two and a half times its own workforce.

### The cap

| cap | budget 900 | budget 2000 |
|---|---|---|
| 1.0 | income 48, ratio 0.25 | income 139, ratio 1.08, ×2.0 |
| 2.0 | income 48, ratio 0.25 — **identical** | — |
| 3.0 | income 48, ratio 0.25 — **identical** | — |
| uncapped | — | income 141, ratio 1.08, ×2.08 |

**At small scale the cap is inert.** Caps of 1.0, 2.0 and 3.0 give identical optima, because the
optimum's park-to-housing ratio is 0.25 — nowhere near any of them. A staffed park is bounded by
water and build cost long before the ratio.

**In a large city it binds, and costs almost nothing.** At budget 2000 best play sits at ratio 1.08,
just above parity, and capping costs 1.4% of income (139 against 141). So the cap stays: it is
irrelevant in the cities players actually build and a cheap guardrail against a water-rich city
converting parks into unbounded labour. Kept deliberately as a bound that does not bite, which is
recorded here so nobody later removes it as dead weight or tunes it as though it were live.

**Water remains the physical brake.** Each park draws 18 against a free baseline of 40, so two parks
is the ceiling with no water plant; beyond that every park needs waterworks, which need power. The cap
governs the *benefit*; water governs the *volume*.

## 5. Implementation

### `Domain.Services.SimulationCalculator`

`total_supply/1` gains one step, scaling the labour entry after the existing reduction:

```elixir
defp total_supply(nodes) do
  supply =
    Enum.reduce(nodes, @baseline_capacity, fn node, acc ->
      Enum.reduce(Node.effective_production(node), acc, &add_resource/2)
    end)

  Map.update!(supply, :labour, &(&1 * labour_multiplier(nodes)))
end

@doc "The amenity multiplier on labour supply: parks per housing block, capped."
@spec labour_multiplier([Node.t()]) :: float()
def labour_multiplier(nodes) do
  housing = effective_count(nodes, :residential)

  if housing > 0.0 do
    parks = effective_count(nodes, :park)
    1.0 + @amenity_per_housing * min(parks / housing, @max_amenity_ratio)
  else
    1.0
  end
end

defp effective_count(nodes, type) do
  Enum.reduce(nodes, 0.0, fn
    %{type: ^type, health: health}, acc -> acc + health / 100.0
    _node, acc -> acc
  end)
end
```

**The `housing > 0.0` guard is mandatory, not defensive.** It is not enough to argue the result would
be multiplied by a zero labour supply anyway — the division happens first. Erlang does not follow IEEE
754 here, so there is no NaN to fall through: measured, `0.0 / 0.0`, `4.0 / 0.0` and `0.0 / 0` all
raise `ArithmeticError`. The guard is what stops an unhoused city crashing the calculator, and with it
the engine, rolling the city back to its last checkpoint. An empty city and a city bulldozed to
nothing but parks both reach this branch on an ordinary tick.

Everything downstream is unchanged. `resource_stats/1` reads `total_supply/1`, so satisfaction,
deficit, `flow_satisfaction`, health decay, the *Tightest* line and the deficit notification all pick
the amenity up with no further edits. The two staffing entries are ordinary consumption and need no
code at all.

### `Domain.Entities.SimulationMetrics`

The LiveView receives metrics and never the city map, and the boundary graph bars
`ArmchairMetropolistWeb` from `Domain.Services` — its `deps` names `Domain`, which exports only
`Entities.*` and `Ports.*`. So both figures the UI needs travel on the metrics struct:

```elixir
amenity: float(),                  # the multiplier, for the Metrics line
amenity_marginal_labour: float()   # supply-side effect of one more park, for the legend
```

`amenity_marginal_labour` is the **supply-side delta only**, computed as an actual difference —
`labour_supply(nodes ++ [fresh park]) − labour_supply(nodes)` — rather than as "`4k`, or `0.0` when
saturated". The two agree everywhere except at the boundary, where a park that takes the ratio from
below the cap to above it contributes only part of `4k`; the difference is exactly right there and the
shortcut is not. Park's own labour consumption is *not* netted in here — §6 nets it in the
presentation layer, where `produced − consumed` already lives.

**Why a field rather than letting the legend derive it.** The legend has
`metrics.by_type[:park].count` and `[:residential].count`, so it could compute the ratio — but those
are raw counts and the domain's ratio is health-weighted. A legend judging saturation on counts would
disagree with the engine for any damaged city, which is the cell-contradicts-itself defect the money
design's amendment already had to fix once.

**No snapshot work.** Only `CityMap` is persisted, `SimulationMetrics` is rebuilt from it every tick,
and `SnapshotVocabulary`'s reachable-struct set is `CityMap` and `Node`. Adding fields here changes
nothing on disk, and neither the two new module attributes nor the two consumption entries introduce
an atom into any stored term.

## 6. Presentation

**Park's labour cell shows the net effect of one more park.** `marginal_cell/2` already computes
`produced − consumed`; for `{:park, :labour}` it substitutes `metrics.amenity_marginal_labour` for the
production term, since the amenity is not in the production table:

| state | amenity | park's own labour | cell |
|---|---|---|---|
| below the cap | +4 | −1 | **+3** |
| at or above the cap | 0 | −1 | **−1** |

That `−1` is a real improvement on the `+0` the un-staffed design would have shown: over-provisioning
parks does not merely stop helping, it costs labour, and the cell says so.

This **keeps** `marginal_cell/2`'s documented contract — "what one more block of this type would do" —
and is exactly that figure. What it relaxes is the parenthetical claim that the figure is "a property
of the type, fixed, not of the current city": the magnitude is fixed at `4k` by §2's algebra, but
whether the city is saturated is city state. That comment must be updated, since a reader trusting the
old wording will not expect the cell to move.

`transit_hub` needs no special handling: its labour is ordinary consumption, so its cell renders `−2`
through the existing path.

**Metrics gains an amenity line**, beside the treasury:

```elixir
<p id="metrics-amenity">Amenity: ×{Float.round(@metrics.amenity, 2)}</p>
```

A city-wide scalar belongs with the other city-wide figures, not in a per-type flow column. Two
decimals because the ratio is continuous — 7 housing and 3 parks gives ×1.43, and one decimal would
collapse distinguishable states.

**Wrap thresholds.** A new Metrics line changes that column's height, not its width, and the
`max-[2010px]` / `max-[1275px]` thresholds are set by width. `Amenity: ×1.43` is shorter than the
existing `supplied/demanded · met this tick` label, so it cannot become the sidebar's widest content.
Confirm on the live page rather than trusting that reasoning — the sidebar is `min-w-fit`, so content
that *did* exceed the current maximum would silently move both windows.

## 7. Rejected alternatives

Each was tried against the simulator; each failed for a reason worth keeping.

**Park produces money.** Rejected on meaning: a public park does not earn revenue. It went in because
money was the resource known to be scarce, which is a reason to look at money, not to make parks a
business.

**Park produces labour additively** (`@production_table` gains `labour: 2.0`). The strongest
candidate — one line, health-scaled for free, picked up by the legend and the guide's generated tables
with no further work — and measurement killed it. At labour 2.0 a city of **1 power plant, 1 water
plant, 5 parks, 1 commercial and zero residential is fully stable**: labour 8/10, money +10. Verified.
Parks would manufacture workers who live nowhere, contradicting the money-and-labour premise that
blocks are "staffed by people who live somewhere". The ratio form keeps every advantage and cannot
express that city.

**Park as a stronger waste sink** (`waste: 8.0 → 30.0`). Verified viable and genuinely useful — three
parks supply an `industrial`'s 90 waste while consuming no labour, freeing the 12 that otherwise blocks
a second `commercial`, measured at +42/tick against +26. Rejected as the primary fix because it makes
`park` a cheaper `industrial` rather than something parks distinctly do, and because the pressure it
relieves is labour, which §2 relieves directly. Worth revisiting on its own merits; not part of this
change.

**A multiplier linear in park count** (`1 + k × parks`). Its flaw is that the bonus is proportional to
city size while its cost is not: at 12 housing one park at k=0.1 is worth +4.8 labour, at 40 housing
the same park is worth +16. A large city converts a handful of parks into an enormous absolute bonus.
Dividing by housing is exactly what removes the size dependence.

**Raising the cap instead of `k`.** Measured to do nothing at all — caps 1.0, 2.0 and 3.0 give
identical optima under staffing, because the ratio at the optimum is 0.25. The cap cannot be the lever
because it is not binding.

## 8. Balance and accepted consequences

**The smallest documented support set stops existing.** Measured by regenerating the guide's
`capacities` block with staffing applied:

| support set | before | after |
|---|---|---|
| 2 power, 1 water, 1 industrial, 1 transit, 1 commercial | 5–5 residential | **none — non-viable** |
| 2 power, 2 water, 1 industrial, 1 transit, 1 commercial | 5–7 | 6–7 |
| 3 power, 3 water, 2 industrial, 2 transit, 2 commercial | 10–12 | 11–12 |

Transit's 2 labour takes that set's labour demand to 22, needing 6 residential, while its single water
plant caps residential at 5. The band is empty. `PlayingGuide`'s `@support_sets` must therefore drop
`{2, 1, 1, 1, 1}` — the smallest viable set becomes `{2, 2, 1, 1, 1}` at 7 support tiles — and the
comment above that list, which currently explains why `{1,1,1,1,1}` is absent, needs the same
explanation for `{2,1,1,1,1}`. Left in place, the published guide would carry a row of `none none none
none`, which the generator renders without complaint.

**Housing erodes somewhat.** At budget 900 the optimum moves from 8 residential (amenity off) to 6
(`k = 1.0`). Housing remains mandatory and substantial — at budget 2000 the optimum is 14 parks against
13 residential, close to parity — but net +3 labour per park sits at the upper end of the band the
additive experiment found safe, and §4 explains why net +2 is not reachable under staffing. Accepted
with the numbers on the record rather than hidden.

**`park` becomes a type you can over-build, and now it hurts.** Past parity, extra parks add water,
money *and* labour demand for no labour gain. The legend's `−1` is the signal. A real trap, but a
legible one, which today's park is not.

**Labour gets tighter city-wide**, which is what makes the amenity matter. The min-residential column
rises for every surviving support set, so a player building a support set with too little housing now
starves for staff sooner.

**Two mechanics govern labour**: a production table and a multiplier. A reader of `@production_table`
alone will not find the amenity rule. Mitigated by the legend cell and the guide's constants block,
not by anything in the table.

**Collapse deepens.** Amenity is health-weighted on both sides, so a failing city loses labour twice
over: dying residential produces less, and dying parks multiply what remains by less — while still
drawing their staffing. Consistent with every other mechanic here, and the guide's rescue section must
say it, because labour will recover more slowly than the housing count suggests.

## 9. Documentation

**`consumption` block** picks up both staffing entries automatically. Verified by regenerating it:
`park` gains labour 1 and `transit_hub` labour 2.

**`capacities` block** changes as tabulated in §8, and `@support_sets` must be edited alongside it.

**`constants` block gains the amenity coefficient and ceiling.** Derived by *measurement*, not by
reading the attributes — matching how `PlayingGuide` already handles the decay and regeneration rates
("module attributes with no public accessor, so they are derived from observed behaviour rather than
duplicated here"): build a city with known housing and parks, read labour supply, solve for `k`, then
push the park count past parity and observe where supply stops rising.

**`production` block is unchanged**, and that is a seam worth naming: amenity is not production, so
`park` still reads "waste 8" there. The guide carries the rule in `constants` and in prose instead.
Putting a multiplier into a table of additive rates would misrepresent it.

**Prose rewrites.** The `park` paragraph in the consumption reference stops being "usually a trap" and
becomes a description of provision. The min-residential explanation currently names `industrial` and
`commercial` as the types needing workers and must add `transit_hub` and `park`. The rescue section
gains the double-decay note above.

## 10. Testing

The follow-ups doc records nine tests on this project that could not fail, all caught by mutation
rather than review. Its two rules apply: **no `refute` without the positive case asserted first**, and
**a test you have not seen fail is not yet a test**. Every test below is broken-first and confirmed
red. `Domain` and `Domain.Services` are both at 100% against a 90% gate, so the new code is fully
covered.

### The multiplier

* **No parks ⇒ multiplier is exactly 1.0**, and labour supply is unchanged from today. Pins the no-op
  case so the multiplier cannot silently apply itself everywhere.
* **Parity ⇒ exactly ×2.0.** Equal effective housing and parks.
* **Above parity ⇒ still ×2.0.** The cap. Kills a missing `min/2`, which nothing else catches —
  asserted well past the ratio, not merely at it.
* **`4k` gross per park below the cap.** For several `(H, P)` pairs, labour supply equals `4H + 4kP`
  exactly. This identity pins `k`, the legend figure and the balance work to each other, so it is
  asserted over several cases rather than one worked example.
* **No housing ⇒ labour supply exactly 0.0, and no raise**, for a city with many parks. Two claims in
  one situation: the arithmetic guard and the design property. A test asserting only `0.0` would pass a
  version that crashed before returning, so the absence of a raise is asserted explicitly.
* **Health-weighted, not counted.** Parks at 50% health give half the amenity of the same city at full
  health. Kills a `length/1` where an effective count belongs. Asserted for the housing side too.

### Staffing

* **`transit_hub` and `park` each draw their labour**, and it is **not** health-scaled: a node at 0
  health still contributes its full labour demand. The second half is the point of putting staffing on
  the consumption side, so it is asserted directly rather than inferred from the table.
* **A dead park is a net labour drain.** Zero amenity contribution and full consumption in the same
  city. This is the behaviour §3 claims staffing buys, so it gets its own test.
* **`power_plant`, `water_plant` and `residential` still draw no labour.** The non-goal in §3 is a
  design commitment; without a test, a future table edit erases it silently.

### `amenity_marginal_labour`

* **Equals `4k` below the cap and `0.0` above it.**
* **Is the true difference at the boundary.** A city positioned so one more park crosses the cap gets
  a value strictly between 0 and `4k` — the case the "`4k` or zero" shortcut gets wrong, and therefore
  the case that justifies computing a difference.

### Presentation

* **Park's labour cell renders `+3`, and `−1` when saturated** — both directions, since a hardcoded
  string satisfies either alone.
* **`transit_hub`'s labour cell renders `−2`** through the ordinary path.
* **Other types' em dashes are unaffected.** Positive case first: assert a type still renders `—` for
  a resource it does not touch, so the park special case cannot leak into the general path.
* **The Metrics amenity line renders two decimals** and moves when parks are placed.

### Documentation

* **`playing_guide_test.exs` passes with the regenerated blocks**, and `@support_sets` no longer
  contains a set that yields `none`. The second is worth asserting rather than eyeballing: a `none`
  row is valid output, so nothing else fails if one is published.

### Not needed

No snapshot test. §5 establishes that nothing persisted changes shape and no new atom enters a stored
term.
