# Park amenity and staffing: every block needs staff except the homes the staff live in — design

**Date:** 2026-08-05
**Status:** designed, not yet implemented
**Ships before:** `2026-08-05-construction-costs-design.md`, which prices `park` and needs it to be
worth buying first

**Amended twice on 2026-08-05, both before implementation.**

*First amendment* added staffing for `transit_hub` and `park`. The two changes cannot ship
separately: staffing `park` drops its net labour contribution, and at the originally specified
`k = 0.5` the net is +1 (at residential's then-4.0 labour), which measurement shows changes nothing. Releasing the amenity alone and
adding staffing afterwards would ship a mechanic that is provably a no-op in between. `k` is
therefore 1.0, not 0.5.

*Second amendment* extended staffing to `power_plant` and `water_plant` and raised `residential`
labour production from 4.0 to 5.0. Staffing two types but not the other two was the weakest line in
this document — a reactor with no operators beside a park with a groundskeeper — and measurement
showed the extension is *better* on every axis once housing supplies 5: no support set is lost (the
first amendment lost one), the guide's `capacities` block returns to within a single cell of its
original values, housing stops eroding, and income rises further. §3 carries the figures. The cost is
four hand-derived test fixtures that must be re-derived; §8 records it.

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
* **No labour draw on `residential`.** It is the sole *source* of labour; a house does not employ
  anyone to be a house. This is the one exemption, and it is what keeps the rule statable.
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

With `H` housing and `P` parks, and `L` the labour a housing block produces (5.0 after §3), below the
cap:

```
labour_supply = LH × (1 + kP/H) = LH + LkP
```

The ratio multiplier **collapses to a constant gross bonus of `Lk` per park** — with `L = 5.0` and
`k = 1.0`, exactly **+5 labour per healthy park**, independent of city size. Verified numerically at
`(H,P) = (6,3), (12,4), (10,5), (8,2)`: every case matches `LH + LkP` to floating-point equality.

Net of the park's own 1 labour (§3), a healthy park below the cap is worth **+4 labour**.

**`L` and `k` are coupled through the legend.** The legend renders `signed/1`, which rounds, so `Lk`
must be a whole number or the cell shows a false figure. `L = 5, k = 1.0` gives 5; `k = 0.75` would
give 3.75 and render as `+3` while supplying 2.75 net. Any future change to either constant has to
preserve the integrality of `Lk`.

Three consequences, and they are why this shape was chosen over the alternatives in §7:

1. **It behaves like an additive bonus**, so balance measured on the additive form transfers.
2. **It is zero when there is no housing.** `0 × anything = 0`. A city of parks and shops with nobody
   living anywhere cannot staff itself — which an additive labour term cannot express.
3. **The legend can show a fixed number**, because the marginal effect does not depend on city size.

## 3. Staffing

Four consumption tables gain a labour entry, and `residential`'s labour production rises to absorb
them. The rule is one clause: **every block needs staff except the homes the staff live in.**

| type | labour drawn | rationale |
|---|---|---|
| `industrial` | 12.0 *(unchanged)* | |
| `commercial` | 8.0 *(unchanged)* | |
| `transit_hub` | **2.0** | Stations and services are staffed |
| `power_plant` | **1.0** | Operators. A reactor is not unattended |
| `water_plant` | **1.0** | Same, and symmetric with power — the two are the same kind of thing |
| `park` | **1.0** | Grounds need keeping |
| `residential` | **none** | The source of labour, not a consumer of it |

And one production change:

| type | before | after |
|---|---|---|
| `residential` | labour 4.0, money 1.0 | **labour 5.0**, money 1.0 |

**`residential` at 5.0 is what makes the rest viable, and it very nearly restores the reference
table.** Measured by regenerating the guide's `capacities` block against the original committed
values:

| support set | original | four staffed, `residential` 4 | four staffed, `residential` 5 |
|---|---|---|---|
| 2 power, 1 water, 1 ind, 1 transit, 1 comm | 5–5 | *(dropped by the first amendment)* | **5–5** |
| 2 power, 2 water, 1 ind, 1 transit, 1 comm | 5–7 | 7 only | **6–7** |
| 3 power, 3 water, 2 ind, 2 transit, 2 comm | 10–12 | **none — non-viable** | **10–12** |

With `residential` at 4 and all four types staffed, the largest documented support set stops existing
and the middle one collapses to a single viable residential count. At 5, the smallest and largest sets
return to *exactly* their original bands and only one cell in the whole block moves. So the first
amendment's loss of a support set is undone rather than deepened.

**`transit_hub` at 2.0 rather than 3.0 is free.** Measured at budgets 900 and 2000, the optimal city
is identical at either value, so this takes the lower end.

**`park` at 1.0 is not free — it forces `k`.** Park's net contribution is `Lk − 1`, so a `k` that
leaves the net too small makes the amenity a no-op — measured, `k = 0.5` (net +1.5) is indistinguishable from no amenity at all. §4 records the search.

### This reverses a documented decision, and replaces its rule

The money-and-labour design (2026-08-02) listed as an explicit non-goal: "No labour requirement on
`power_plant`, `water_plant`, `transit_hub` or `park`. Staffing every type would make labour a
near-universal tax and flatten the distinction being drawn."

All four are now staffed, so that non-goal is fully reversed rather than half-reversed. The concern
behind it is real and is answered differently: labour is no longer a *distinction between types*, it
is a **cost of building anything that is not housing**. That is a cleaner rule than the one it
replaces — the old line ("industry and commerce are staffed, infrastructure is not") had no
defensible reason why a transit hub or a power plant runs unattended, and the intermediate line the
first amendment drew ("utilities are automated") was weaker still.

What keeps labour from being a flat tax on everything is the exemption, not the omissions:
`residential` alone produces labour and consumes none, so every non-housing block placed increases the
housing the city needs. That is the pressure the original spec wanted, expressed as a rule with one
exception instead of a table with four.

**Staffing is what gives `park` teeth on the downside.** The amenity is health-weighted; consumption
never is. So a park at zero health provides **no** amenity while still drawing its full 1 labour, 18
water and 3 money — a pure drain. Before this, neglecting a park cost 8 waste capacity and nothing
else. This is the asymmetry the engine is built on, finally applying to `park`.

**It also makes the ratio cap nearly redundant** (§4): a staffed park limits its own usefulness, so
water and build cost bind before the ratio does in any ordinary city.

## 4. Why these constants

Settled by search, not argument. The search enumerates every combination of the seven types within
stated bounds, keeps those where all six resources are satisfied at full health and money does not run
a long-run deficit, and reports the highest-income city within a build budget.

### `k`, with all four types staffed and `residential` at 5, budget 900

| k | best income | parks | residential | multiplier |
|---|---|---|---|---|
| 0.0 | 50 | 1 | 7 | ×1.0 |
| 0.5 | 50 | 1 | 7 | ×1.07 |
| 0.75 | 74 | 3 | 7 | ×1.32 |
| **1.0** | **74** | **3** | **7** | **×1.43** |
| 1.5 | 99 | 4 | 5 | ×2.2 |

**`k = 1.0` is the value to take**, for two reasons rather than one. It clears the threshold — at 0.5
the amenity is indistinguishable from absent, giving a byte-identical optimum to `k = 0.0`. And it is
the smallest value at or above the threshold that keeps `Lk` a whole number (§2): `k = 0.75` reaches
the same optimum but makes the gross bonus 3.75, which the legend would round to a figure it does not
supply.

**Housing does not erode at `k = 1.0`.** Residential sits at 7 both with the amenity and without it,
and at budget 2000 it is 17 without and 16 with. This is a direct improvement on the first
amendment's numbers, where residential fell from 8 to 6 — because housing supplying 5 labour instead
of 4 makes it a better labour source, so parks stop competing with it and start complementing it.

**`k = 1.5` overshoots.** Income 99, but residential falls to 5 and the multiplier reaches ×2.2.

### The cap

Measured under the first amendment's tables, the cap bound at ratio 1.08 at budget 2000. **Under this
version it never binds in measured play**: the optimum's park-to-housing ratio is 0.43 at budget 900
and 0.19 at budget 2000, because housing at 5 labour needs fewer parks to reach any given labour
target. Caps of 1.0, 2.0 and 3.0 gave byte-identical optima even before `residential` rose.

It stays at 1.0 anyway, as a bound that does not bite: without it, a water-rich city could push the
ratio and therefore the multiplier arbitrarily high, and the cost of keeping it is measured at zero.
Recorded explicitly so nobody later removes it as dead weight *or* tunes it as though it were live —
it is neither.

**Water remains the physical brake.** Each park draws 18 against a free baseline of 40. Counting the
housing a park needs to staff it and the income it needs to cover its 3 money upkeep, **one** park is
the ceiling with no water plant: measured, one house plus one park plus one commercial block sits at
water 38/40 and +28 money per tick and holds indefinitely, while a second park reaches 56/40 and dies.
Beyond one, every park needs waterworks, which need power. The cap governs the *benefit*; water governs
the *volume*.

(Corrected 2026-08-05 during implementation. This paragraph previously claimed two parks were the
ceiling — a figure measured before `park` drew labour and never re-measured after staffing landed. It
reached `docs/PLAYING.md` before the task review caught it.)

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
`Entities.*` and `Ports.*`. So every figure the UI needs travels on the metrics struct:

```elixir
amenity: float(),                   # the multiplier, for the Metrics line
amenity_marginal_labour: float(),   # supply-side effect of one more park, for the legend
amenity_labour: float()             # what the placed parks contribute, for the legend
```

**`amenity_labour` was added during implementation, and the omission was a shipped bug.** This
section originally specified two fields, on the assumption that the legend's park/labour cell needed
only the marginal figure. It does not: the cell stacks *two* figures, and the lower, bolder one is a
total. With no total to render it fell through to `total_cell/2`'s `is_nil(produced)` branch and
reported park's bare staffing draw — at 4 housing and 3 parks, a bold `−3` where the honest figure is
`+12`. A marginal cannot stand in for a total here: below the cap they differ by the park count, and
at the cap the marginal is `0.0` while the total is at its largest. Like the marginal, it is computed
as a real difference — `labour_supply(nodes) − labour_supply(nodes without parks)` — because below
the cap it equals `Lk × parks` but at the cap it equals `Lk × housing`.

`amenity_marginal_labour` is the **supply-side delta only**, computed as an actual difference —
`labour_supply(nodes ++ [fresh park]) − labour_supply(nodes)` — rather than as "`Lk`, or `0.0` when
saturated". The two agree everywhere except at the boundary, where a park that takes the ratio from
below the cap to above it contributes only part of `Lk`; the difference is exactly right there and the
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
| below the cap | +5 | −1 | **+4** |
| at or above the cap | 0 | −1 | **−1** |

That `−1` is a real improvement on the `+0` the un-staffed design would have shown: over-provisioning
parks does not merely stop helping, it costs labour, and the cell says so.

This **keeps** `marginal_cell/2`'s documented contract — "what one more block of this type would do" —
and is exactly that figure. What it relaxes is the parenthetical claim that the figure is "a property
of the type, fixed, not of the current city": the magnitude is fixed at `Lk` by §2's algebra, but
whether the city is saturated is city state. That comment must be updated, since a reader trusting the
old wording will not expect the cell to move.

`transit_hub` needs no special handling: its labour is ordinary consumption, so its cell renders `−2`
through the existing path.

**Metrics gains a workforce line**, beside the treasury:

```elixir
<p id="metrics-workforce">Workforce: ×{Float.round(@metrics.amenity, 2)}</p>
```

A city-wide scalar belongs with the other city-wide figures, not in a per-type flow column. Two
decimals because the ratio is continuous — 7 housing and 3 parks gives ×1.43, and one decimal would
collapse distinguishable states.

**The player-facing word is "Workforce"; the domain word stays "amenity", and the split is
deliberate.** `amenity` names the *cause* — parks are an amenity — and belongs with the rule in
`SimulationCalculator`. A player does not care what the mechanism is called; they care that their
workforce is 1.43 times what their housing alone would field, which is what the figure means. So the
struct field, the module attributes and the tests keep `amenity`, while the label and the element id
(`metrics-workforce`) use the player's word. Recorded so nobody later "fixes" the mismatch in either
direction.

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

**Every documented support set survives, and the reference table barely moves.** Measured by applying
the whole change and regenerating the guide: one cell in the `capacities` block changes (the middle
set's minimum, 5 → 6) and no set is lost. §3 carries the table. `PlayingGuide`'s `@support_sets` needs
no edit — a conclusion that only holds because `residential` rose to 5, and one the first amendment
could not reach.

**Housing does not erode.** At budget 900 the optimum holds 7 residential with the amenity and 7
without it; at budget 2000 it is 16 with and 17 without. Parks stop competing with housing as a labour
source because housing became a better one. This is the clearest gain from raising `residential` to 5:
the first amendment's numbers had residential falling from 8 to 6.

**Four hand-derived test fixtures must be re-derived, and this is the real cost of the change.**
Staffing `power_plant` and `water_plant` breaks the premises of four fixtures in
`simulation_calculator_test.exs` that compute exact satisfactions in their comments — a power plant
whose worst ratio was water's 0.95 now has labour's 0.0 and takes full decay instead of 0.30. Each
needs one residential block added to supply labour, and its water plant's health re-solved against the
new water demand of 86.0: measured, 30.3 → **41.7** for the sub-rounding fixture and 24.1333 →
**34.5333** for the status-flip one. Both were verified by running the suite green, and the plan
carries the tested values. Delicate rather than hard, but this is exactly the shape of change that has
produced tests that pass while checking nothing on this project before.

**`park` becomes a type you can over-build, and now it hurts.** Past parity, extra parks add water,
money *and* labour demand for no labour gain. The legend's `−1` is the signal. A real trap, but a
legible one, which today's park is not.

**Labour becomes the cost of building anything that is not housing.** That is the point of the rule in
§3, and it is what makes the amenity matter: every non-residential block placed raises the housing the
city needs, so a player who builds support without building homes starves for staff rather than for
power.

**Two mechanics govern labour**: a production table and a multiplier. A reader of `@production_table`
alone will not find the amenity rule. Mitigated by the legend cell and the guide's constants block,
not by anything in the table.

**Collapse does *not* deepen — corrected during implementation, after measurement.** The draft of
this section claimed a failing city loses labour twice over, because amenity is health-weighted on
both sides. That is wrong, and the arithmetic says so: the multiplier is `1 + k × min(P_eff/H_eff,
cap)`, and health scales *numerator and denominator alike*, so damage falling evenly on housing and
parks **cancels in the ratio**. Measured, 4 housing + 2 parks: at 100 health, ×1.5 and 30.0 labour;
at 50 health, still ×1.5 and 15.0 labour — a *linear* fall, tracking the housing. Worse for the
draft's story, uneven damage can move the ratio the other way: housing at 50 with parks at 100 gives
ratio 1.0, ×2.0, and **20.0** labour, more than the uniformly damaged city's 15.0. Only the
parks-more-damaged-than-housing case loses labour faster than the block count suggests, and that is
what the guide's rescue section says. Do not re-derive the "twice over" version.

## 9. Documentation

**`consumption` block** picks up all four staffing entries automatically. Verified by regenerating it:
`park` and both plants gain labour 1, `transit_hub` labour 2.

**`production` block** changes too, which the first amendment did not touch: `residential` reads
`labour 5, money 1`.

**`capacities` block** moves by exactly one cell (§8) and `@support_sets` needs **no** edit.

**`constants` block gains the amenity coefficient and ceiling.** Derived by *measurement*, not by
reading the attributes — matching how `PlayingGuide` already handles the decay and regeneration rates
("module attributes with no public accessor, so they are derived from observed behaviour rather than
duplicated here"): build a city with known housing and parks, read labour supply, solve for `k`, then
push the park count past parity and observe where supply stops rising.

**`park`'s `production` row is still just "waste 8"**, and that is a seam worth naming: amenity is not
production, so no table shows park's labour effect. The guide carries the rule in `constants` and in
prose instead. Putting a multiplier into a table of additive rates would misrepresent it.

**A new rule at the top of the guide: build a house first.** This is the largest documentation
consequence of the change and it is not advice, it is a fact about the game. Measured, with a single
block alone on an empty grid:

| block | labour demand / supply | offline at | dead at |
|---|---|---|---|
| `residential` | 0 / 5 | never | never |
| every other type | 1–12 / 0 | tick 14 | tick 17 |

Six of the seven types cannot survive a single tick's worth of neglect without housing, because labour
satisfaction is 0.0 and they take the full decay. A city with no people is not merely unproductive, it
is uninhabitable by its own infrastructure.

This **contradicts the guide's current headline advice**, "Build producers first", which was correct
when labour was a tax on two types: demand arrives instantly and in full, so a consumer placed before
its support does damage. That is still true *between* the other five resources, but it is now
subordinate to housing — a power plant placed first is dead in 17 ticks with nothing to show for it.
The advice becomes: **one house, then producers, then the rest.**

**Prose rewrites.** The `park` paragraph in the consumption reference stops being "usually a trap" and
becomes a description of provision. The min-residential explanation currently names `industrial` and
`commercial` as the types needing workers and must instead state the rule: everything except
`residential` draws staff. "Why your first city dies" needs the housing-first rule alongside it. The
rescue section gains the double-decay note above.

## 10. Testing

The follow-ups doc records nine tests on this project that could not fail, all caught by mutation
rather than review. Its two rules apply: **no `refute` without the positive case asserted first**, and
**a test you have not seen fail is not yet a test**. Every test below is broken-first and confirmed
red. `Domain` and `Domain.Services` are both at 100% against a 90% gate, so the new code is fully
covered.

### The multiplier

* **No parks ⇒ multiplier is exactly 1.0**, and labour supply is unchanged from today. Pins the no-op
  case so the multiplier cannot silently apply itself everywhere.
* **Parity ⇒ exactly ×2.0.** Equal effective housing and parks. With `L = 5`, a 6-housing
  6-park city supplies exactly 60.0.
* **Above parity ⇒ still ×2.0.** The cap. Kills a missing `min/2`, which nothing else catches —
  asserted well past the ratio, not merely at it.
* **`Lk` gross per park below the cap.** For several `(H, P)` pairs, labour supply equals `LH + LkP`
  exactly — 45.0, 80.0, 75.0 and 50.0 for `(6,3), (12,4), (10,5), (8,2)`. This identity pins `L`, `k`,
  the legend figure and the balance work to each other, so it is asserted over several cases rather
  than one worked example.
* **No housing ⇒ labour supply exactly 0.0, and no raise**, for a city with many parks. Two claims in
  one situation: the arithmetic guard and the design property. A test asserting only `0.0` would pass a
  version that crashed before returning, so the absence of a raise is asserted explicitly.
* **Health-weighted, not counted.** Parks at 50% health give half the amenity of the same city at full
  health. Kills a `length/1` where an effective count belongs. Asserted for the housing side too.

### Staffing

* **All four staffed types draw their labour**, and it is **not** health-scaled: a node at 0 health
  still contributes its full labour demand. The second half is the point of putting staffing on the
  consumption side, so it is asserted directly rather than inferred from the table.
* **A dead park is a net labour drain.** Zero amenity contribution and full consumption in the same
  city. This is the behaviour §3 claims staffing buys, so it gets its own test.
* **`residential` draws no labour, and produces 5.0.** The sole exemption in §3's rule is a design
  commitment; without a test, a future table edit erases it silently. The production figure is pinned
  because `L` is half of the `Lk` integrality constraint (§2).

### `amenity_marginal_labour`

* **Equals `Lk` = 5.0 below the cap and `0.0` above it.**
* **Is the true difference at the boundary.** A city positioned so one more park crosses the cap gets
  a value strictly between 0 and `Lk` — the case the "`Lk` or zero" shortcut gets wrong, and therefore
  the case that justifies computing a difference.

### `amenity_labour`

* **Equals `Lk × parks` below the cap** — 4 housing and 3 parks gives 15.0, from a labour supply of
  35.0 against 20.0 with the parks removed.
* **Equals `Lk × housing` at or past the cap** — 2 housing and 3 parks gives 10.0, not 15.0. This is
  the case a `Lk × parks` shortcut gets wrong, and so the case that justifies the difference.
* **Is `0.0` with no parks**, rather than the whole labour supply. Guards the subtraction's second
  term against a swapped operand, which would otherwise attribute all of housing's output to an
  amenity that is absent.

### Presentation

* **Park's labour cell renders `+4` on its marginal line, and `−1` when saturated** — both
  directions, since a hardcoded string satisfies either alone.
* **Park's labour *total* line renders `+12` at 4 housing and 3 parks, and `+7` at 2 housing and 3
  parks.** Asserted on `.font-semibold` inside the cell rather than on the cell, because the cell's
  text also contains the marginal figure and a cell-level assertion silently matches the wrong line.
  Both figures are net of park's own staffing. The second case is at the cap, where the total is
  bounded by the housing — so a total derived from the marginal, or from the park count, fails it.
* **`transit_hub`'s labour cell renders `−2` and `power_plant`'s `−1`** through the ordinary path.
* **Other types' em dashes are unaffected.** Positive case first: assert a type still renders `—` for
  a resource it does not touch, so the park special case cannot leak into the general path.
* **The Metrics workforce line renders two decimals** and moves when parks are placed. Asserted on
  `#metrics-workforce`, and on the label reading "Workforce" — the player-facing word is a decision, so
  a rename should fail a test rather than pass silently. The precision needs a ratio that is not a
  tenth to pin it at all: ×1.5 renders identically at one decimal and two, so 3 housing and 1 park
  (×1.33 against ×1.3) is the case that discriminates them.

### Documentation

* **`playing_guide_test.exs` passes with the regenerated blocks**, and no support set yields `none`.
  Worth asserting rather than eyeballing: a `none` row is valid generator output, so nothing else
  fails if one is published. It passes today, but it is the assertion that would have caught the first
  amendment's lost support set.

### Not needed

No snapshot test. §5 establishes that nothing persisted changes shape and no new atom enters a stored
term.
