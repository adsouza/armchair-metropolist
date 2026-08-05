# Park amenity: parks multiply the labour their housing supplies — design

**Date:** 2026-08-05
**Status:** designed, not yet implemented
**Ships before:** `2026-08-05-construction-costs-design.md`, which prices `park` and needs it to be
worth buying first

## 1. Problem

`park` is the one node type with no reason to exist. `docs/PLAYING.md` says so directly — "usually a
trap — it trades a lot of water for a little waste capacity, so it only pays when you have spare
water and are waste-limited, which is rare given how much `industrial` supplies" — and the numbers
bear it out: 18 water and 3 money per tick buys 8 waste capacity, against `industrial`'s 90.

Measured, searching all stable solvent cities under a 900 build budget for maximum income, the
optimum contains exactly **one** park. It is not quite worthless; it is worth almost exactly one
tile and no more.

That is tolerable while placement is free. It stops being tolerable the moment construction costs
land, because then `park` is a type you pay 20 for and would never want. So `park` needs value
before that change ships, which is why this design goes first.

### Non-goals

* **No new resource.** The six-resource vocabulary is unchanged.
* **No change to `park`'s consumption.** Water 18, traffic 2, money 3 all stay. Thirst is `park`'s
  character and, as §3 shows, its balancing constraint.
* **No adjacency or service radius.** `docs/PLAYING.md` records that position does not matter
  anywhere in this engine, and a park that cared about distance would be the first exception. That
  is a much larger design.
* **No amenity effect on any resource but labour.**
* **No re-pricing of `park`.** Its construction cost is the other spec's business.

## 2. The rule

Total labour supply is multiplied by an amenity factor derived from how much park there is *per
housing block*:

```
housing  = Σ residential health / 100          # effective housing
parks    = Σ park        health / 100          # effective parks

amenity  = 1 + k × min(parks / housing, cap)   when housing > 0
amenity  = 1                                   when housing = 0

labour_supply = (baseline + Σ health-scaled labour production) × amenity
```

with

```elixir
@amenity_per_housing 0.5   # k
@max_amenity_ratio   1.0   # cap: one park per housing block is full provision
```

So the multiplier runs from ×1.0 to a maximum of **×1.5**, reached when parks equal housing.

**Both sides are health-weighted, not counted.** A neglected park provides no amenity, and a dying
neighbourhood needs fewer parks to serve it. This follows the same rule as every other benefit in
the engine: production is scaled by health and consumption is not, and a buff that ignored health
would make `park` the one type neglect cannot punish.

### The algebra that makes this work

With `H` housing and `P` parks, below the cap:

```
labour_supply = 4H × (1 + kP/H) = 4H + 4kP
```

The ratio multiplier **collapses to a constant bonus of `4k` per park** — with `k = 0.5`, exactly
**+2 labour per healthy park**, independent of city size. Verified numerically at
`(H,P) = (6,6), (6,3), (12,4), (10,10)`: every case matches `4H + 4kP` to within floating-point
equality.

Three consequences, and they are the whole reason this shape was chosen:

1. **It behaves like the additive version that measurement already validated** (§3), so the balance
   work transfers.
2. **It is zero when there is no housing.** `0 × anything = 0`. A city of parks and shops with
   nobody living anywhere cannot staff itself, which an additive labour term cannot express — see
   §6.
3. **The legend can show a fixed number.** Because the marginal effect does not depend on city size,
   `+2` is a truthful constant rather than a figure that drifts with the city (§5).

## 3. Why a ratio, and why capped

Both settled by search rather than argument. The search enumerates every combination of the seven
types within stated bounds, keeps those where all six resources are satisfied at full health and
money does not run a long-run deficit, and reports the highest-income city within a 900 build
budget.

| ratio cap | best income | parks | residential |
|---|---|---|---|
| none (today) | 50 | 1 | 7 |
| 0.5 | 50 | 1 | 7 |
| **1.0** | **59** | **6** | **6** |
| 2.0 | 59 | 6 | 6 |
| uncapped | 68 | 12 | **3** |

**A cap of 1.0 is right because caps 1.0 and 2.0 give the identical optimum.** Best play already
lands at 6 parks against 6 housing — ratio exactly 1.0 — so the cap does not constrain the intended
game at all. It binds only on the uncapped case, where the optimiser runs to 12 parks against 3
housing (amenity ×3.0) and housing erodes from 7 to 3. A ceiling that leaves good play untouched
while forbidding the degenerate outcome is the shape to want.

**A cap of 0.5 is too tight to do anything**: the optimum is byte-identical to no bonus at all.

**`k = 0.5` is the smallest value that changes any decision.** From the equivalent additive
experiment: at +1 labour per park the optimal city is identical to the unbuffed one — same single
park, same 7 residential, same income 50. At +2 it becomes 6 parks and 6 residential at income 59.
At +3 residential falls to 4, and at +4 the optimum contains **zero** residential. So the usable
band for the per-park bonus is narrow, `4k` must land in it, and `k = 0.5` puts it at 2.

**Water remains the physical brake.** Each park draws 18 against a free baseline of 40, so two parks
is the ceiling with no water plant; beyond that every park needs waterworks, which need power. The
cap governs the *benefit*; water governs the *volume*.

## 4. Implementation

### `Domain.Services.SimulationCalculator`

`total_supply/1` gains one step. It currently reduces health-scaled production over the baseline;
now it scales the labour entry afterwards:

```elixir
defp total_supply(nodes) do
  supply =
    Enum.reduce(nodes, @baseline_capacity, fn node, acc ->
      Enum.reduce(Node.effective_production(node), acc, &add_resource/2)
    end)

  Map.update!(supply, :labour, &(&1 * labour_multiplier(nodes)))
end

@doc """
The amenity multiplier on labour supply: parks per housing block, capped.
"""
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

**The `housing > 0.0` guard is mandatory, not defensive.** It is not enough to argue that the result
would be multiplied by a zero labour supply anyway — the division happens first. Erlang does not
follow IEEE 754 here, so there is no NaN to fall through: measured, `0.0 / 0.0`, `4.0 / 0.0` and
`0.0 / 0` all raise `ArithmeticError`. The guard is therefore what stops an unhoused city crashing
the calculator, and with it the engine, rolling the city back to its last checkpoint. An empty city
and a city bulldozed to nothing but parks both reach this branch on an ordinary tick.

Everything downstream is unchanged. `resource_stats/1` reads `total_supply/1`, so satisfaction,
deficit, `flow_satisfaction`, health decay, the *Tightest* line and the deficit notification all pick
the amenity up with no further edits.

### `Domain.Entities.SimulationMetrics`

The LiveView receives metrics and never the city map, and the boundary graph bars
`ArmchairMetropolistWeb` from `Domain.Services` — its `deps` list names `Domain`, which exports only
`Entities.*` and `Ports.*`. So both figures the UI needs have to travel on the metrics struct:

```elixir
@type t :: %__MODULE__{
        # … existing fields …
        amenity: float(),                  # the multiplier, for the Metrics line
        amenity_marginal_labour: float()   # what one more park adds to labour supply, for the legend
      }
```

`amenity_marginal_labour` is computed as an actual difference —
`labour_supply(nodes ++ [fresh park]) − labour_supply(nodes)` — rather than as "`4k`, or `0.0` when
saturated". The two agree everywhere except at the boundary, where a park that takes the ratio from
below the cap to above it contributes only part of `4k`, and the difference is exactly right there
while the shortcut is not.

**Why a second field rather than letting the legend derive it.** The legend has
`metrics.by_type[:park].count` and `[:residential].count` already, so it could compute the ratio
itself — but those are raw counts and the domain's ratio is health-weighted. A legend that judged
saturation on counts would disagree with the engine for any damaged city, which is the
cell-contradicts-itself defect the money design's amendment already had to fix once.

**No snapshot work.** Only `CityMap` is persisted (`save/3` writes `city_map`), `SimulationMetrics`
is rebuilt from it every tick, and `SnapshotVocabulary`'s reachable-struct set is `CityMap` and
`Node`. Adding fields here changes nothing on disk. The two new module attributes introduce no atoms
into any stored term either.

## 5. Presentation

**Park's labour cell shows the amenity contribution.** Today `marginal_cell(:park, :labour)` renders
an em dash, because `park` appears in neither table for `labour` — and the em dash means "does not
interact with this resource at all", which would become a lie. It renders `signed/1` of
`metrics.amenity_marginal_labour` instead: `+2` normally, `+0` once parks have reached housing.

This is a deliberate special case in `marginal_cell/2`, and it *keeps* that function's documented
contract rather than breaking it. The docstring promises "what one more block of this type would do",
and the amenity figure is exactly that. What it does relax is the parenthetical claim that the
figure is "a property of the type, fixed, not of the current city" — the magnitude is fixed at `4k`
by §2's algebra, but whether the city is saturated is city state. The comment must be updated to say
so, since a reader who trusts the old wording will not expect the cell to move.

`+0` against a `—` elsewhere in the same column is meaningful here and reads correctly: `park` does
interact with labour, and right now one more would add nothing.

**Metrics gains an amenity line**, beside the treasury:

```elixir
<p id="metrics-amenity">Amenity: ×{Float.round(@metrics.amenity, 2)}</p>
```

A city-wide scalar belongs with the other city-wide figures, not in a per-type flow column. Two
decimals because the ratio is continuous — with 7 housing and 3 parks the multiplier is ×1.21, and
rounding to one decimal would collapse distinguishable states.

**Wrap thresholds.** Adding a line to Metrics changes that column's height, not its width, and the
`max-[2010px]` / `max-[1275px]` thresholds are set by width. `Amenity: ×1.21` is shorter than the
existing `supplied/demanded · met this tick` label, so it cannot become the widest content in the
sidebar. Confirm on the live page rather than trusting that reasoning — the sidebar is `min-w-fit`,
so any content that *did* exceed the current maximum would silently move both windows.

## 6. Rejected alternatives

Recorded because each was tried against the simulator and each failed for a reason worth keeping.

**Park produces money.** Rejected on meaning: a public park does not earn revenue. It also went in
because money was the resource known to be scarce, which is a reason to look at money, not a reason
to make parks a business.

**Park produces labour additively** (`@production_table` gains `labour: 2.0`). This was the
strongest candidate — one line, health-scaled for free, picked up by the legend and the guide's
generated tables with no further work — and measurement killed it. At labour 2.0 a city of **1 power
plant, 1 water plant, 5 parks, 1 commercial and zero residential is fully stable**: labour 8/10,
money +10. Verified. Parks would manufacture workers who live nowhere, which contradicts the founding
premise of the money-and-labour design, that "the industrial and commercial blocks are staffed by
people who live somewhere". The ratio form in §2 keeps every advantage of this option and cannot
express that city.

**Park as a stronger waste sink** (`waste: 8.0 → 30.0`). Verified viable and genuinely useful — three
parks supply an `industrial`'s 90 waste while consuming **no labour**, which frees the 12 that
otherwise blocks a second `commercial`, measured at +42/tick against +26. Rejected as the *primary*
fix because it makes `park` a cheaper `industrial` rather than something parks distinctly do, and
because the pressure it relieves is labour, which §2 relieves directly. Worth revisiting on its own
merits later; it is not part of this change.

**A multiplier linear in park count** (`1 + k × parks`, capped or not). The shape considered before
the ratio was proposed. Its flaw is that the bonus is proportional to city size while its cost is
not: at 12 housing one park at k=0.1 is worth +4.8 labour, at 40 housing the same park is worth +16.
A large city therefore converts a handful of parks into an enormous absolute bonus. The ratio form
fixes this by construction — dividing by housing is exactly what removes the size dependence.

## 7. Balance

**What the multiplier is worth.** At full provision (parks = housing) labour supply rises by half.
For the 6-park, 6-housing optimum: 24 labour becomes 36, which is the 12 extra that funds a third
`commercial` and takes income from 50 to 59.

**Park's place in the ratio.** `docs/PLAYING.md`'s equilibrium — roughly 3 power : 3 water : 2
industrial : 2 transit : 2 commercial per 12 residential — gains parks as an income lever rather
than a requirement. A city that never builds one is still viable; it just cannot reach the incomes a
park-provisioned city can at the same footprint.

**The interaction with collapse is worth naming.** Amenity is health-weighted on both sides, so a
neglected city loses labour twice over: dying residential produces less labour *and* dying parks
multiply what remains by less. That deepens the existing spiral. It is consistent with every other
mechanic here, and `docs/PLAYING.md`'s rescue section needs to say it, because a player rescuing a
city will find labour recovering more slowly than the housing count suggests.

## 8. Accepted consequences

**`park` becomes a type you can over-build.** Past parity with housing, extra parks add water and
money demand for no labour gain — the legend's `+0` is the only signal. That is a real trap, but a
*legible* one, which the current park is not.

**Two mechanics now govern labour**, its production table and a multiplier. A reader of
`@production_table` alone will not find the amenity rule. Mitigated by the legend cell and the
guide's constants block (§9), not by anything in the table itself.

**`docs/PLAYING.md`'s production table cannot show this.** Amenity is not production, so the
generated `production` block is unchanged and `park` still reads "waste 8". The guide has to carry
the rule in the `constants` block and in prose instead. Recorded as a documentation seam rather than
solved: putting a multiplier in a table of additive rates would misrepresent it.

**The `capacities` block is unaffected**, verified by construction: `residential_range/5` builds
support sets from power, water, industrial, transit, commercial and residential only, so parks are
always zero there and the multiplier is always exactly 1.0.

## 9. Documentation

**`constants` block gains two rows** — the coefficient and the ceiling. Derived by *measurement*, not
by reading the attributes, matching how `PlayingGuide` already handles the decay and regeneration
rates ("module attributes with no public accessor, so they are derived from observed behaviour rather
than duplicated here"): build a city with known housing and parks, read labour supply, and solve for
`k`; then raise the park count past parity and observe where supply stops rising.

**The `park` paragraph in the consumption reference is rewritten.** "Usually a trap" becomes a
description of provision: parks raise the labour their housing supplies, up to one park per housing
block, after which they do nothing for labour.

**The rescue section gains the double-decay note** from §7.

## 10. Testing

The follow-ups doc records nine tests on this project that could not fail, all caught by mutation
rather than review. Its two rules apply: **no `refute` without the positive case asserted first**,
and **a test you have not seen fail is not yet a test**. Every test below is broken-first and
confirmed red.

`Domain` and `Domain.Services` are both at 100% coverage against a 90% gate, so the new code is
fully covered.

### The rule

* **No parks ⇒ multiplier is exactly 1.0**, and labour supply is unchanged from today. Pins the
  no-op case so the multiplier cannot silently apply itself to every city.
* **Parity ⇒ exactly ×1.5.** Equal effective housing and parks.
* **Above parity ⇒ still ×1.5.** The cap. Kills a missing `min/2`, which nothing else catches — and
  asserted against a ratio well past 1.0, not just at it.
* **`4k` per park below the cap.** For several `(H, P)` pairs, labour supply equals `4H + 4kP`
  exactly. This is the property that pins `k`, the legend's `+2` and the balance work to each other,
  so it is asserted as an identity over several cases rather than one worked example.
* **No housing ⇒ labour supply exactly 0.0, and no raise**, for a city with many parks. Two distinct
  claims in one situation: the arithmetic guard, and the design property that the unhoused city
  cannot staff anything. A test that only asserted `0.0` would pass a version that crashed before
  returning — so the absence of a raise is asserted, not assumed.
* **Health-weighted, not counted.** A city whose parks sit at 50% health gets half the amenity of
  the same city at full health. Kills a `length/1` where an effective count belongs.
* **A city of one industrial and enough housing stays alive only with parks**, or some equivalent
  end-to-end case: the requirement is that amenity changes what a city can sustain, and that
  deserves a direct test rather than being inferred from the multiplier's value.

### `amenity_marginal_labour`

* **Equals `4k` below the cap and `0.0` above it.**
* **Is the true difference at the boundary.** A city positioned so that one more park crosses the cap
  gets a value strictly between 0 and `4k`. This is the case the "`4k` or zero" shortcut gets wrong,
  so it is the case that justifies computing a difference — without it the shortcut passes.

### Presentation

* **Park's labour cell renders `+2`, and `+0` when saturated** — both directions, since a hardcoded
  string satisfies either alone.
* **Other types' em dashes are unaffected.** Positive case first: assert some type still renders `—`
  for a resource it does not touch, so the special case cannot leak into the general path.
* **The Metrics amenity line renders two decimals** and moves when parks are placed.

### Not needed

No snapshot test. §4 establishes that nothing persisted changes shape and no new atom enters a stored
term.
