# Waste as an accumulating stock — design

**Date:** 2026-08-07
**Status:** designed, not yet implemented
**Follows:** `2026-08-07-negative-resource-polarity-design.md` §10, which deferred this and named
three objections. §7 below records that one of the three is measurably false and a second is
narrower than stated.

## 1. Problem

`waste` reads as a bad that rises, but it does not *accumulate*. Outrun your disposal capacity
for ten ticks and the eleventh tick is no worse than the first: each tick's unprocessed waste is
discarded at the tick boundary. The word the polarity change taught players — a landfill filling
up — describes a mechanic the engine does not have.

Money is the one resource whose surplus survives the boundary. This gives waste the same
treatment with the opposite sign: unprocessed waste becomes a **stock** that adds to the next
tick's load and drains when the city has spare capacity.

### Non-goals

* **No accumulation for `traffic`.** A landfill persists; a traffic jam clears when the rush
  ends. `traffic` stays a per-tick flow. `@carryover` is the extension point if that is ever
  revisited, but the asymmetry is a fact about the world, not an arbitrary rule.
* **No cap on the stock.** It drains at `capacity − emissions` per tick whenever that is
  positive, which already bounds recovery; a ceiling would be a third tuned constant with no
  measured basis.
* **No natural decay of the stock.** A landfill that empties itself makes `industrial` optional,
  which is the mechanic this is meant to make urgent.
* **No new resource, no table value changes.** The six-resource vocabulary and all three tables
  in `Node` are untouched.
* **No change to `@decay_per_tick`, `@regen_per_tick`, or any construction cost.** §4 records
  that the *meaning* of the decay constant changes even though its value does not.

## 2. The rule

`@carryover` gains `:waste`, and `carried/2` returns the stock **negated**:

```elixir
@carryover [:money, :waste]

defp carried(city_map, :money), do: city_map.money
defp carried(city_map, :waste), do: -city_map.waste_stock
defp carried(_city_map, _resource), do: 0.0
```

Everything else is arithmetic `resource_stats/1` already performs:

```
available   = supplied + carried        = supplied − stock
satisfaction= min(1.0, available / demanded)
deficit     = max(0.0, demanded − available) = max(0.0, demanded − supplied + stock)
```

and that `deficit` **is** the next tick's stock. So `advance_tick/1` gains one line beside the
money balance, and no new formula is written anywhere:

```elixir
waste_stock = Map.fetch!(stats, :waste).deficit
```

**The drain rate is `capacity − emissions` per tick**, which nobody writes down — it falls out of
`max(0, demanded − supplied + stock)`. Worked, at emissions 52 and capacity 56:

| tick | stock in | available | deficit → stock out |
|---|---|---|---|
| 1 | 0 | 56 | 0 |
| — demolish the industrial block: capacity drops to 26 — | | | |
| 2 | 0 | 26 | 26 |
| 3 | 26 | 0 | 52 |
| 4 | 52 | −26 | 78 |
| — build it back: capacity 116 — | | | |
| 5 | 78 | 38 | 14 |
| 6 | 14 | 102 | 0 |

### Why the two satisfaction fields already model this

`SimulationMetrics.resource_stats`'s typedoc says `satisfaction` is balance-inclusive and drives
health decay, while `flow_satisfaction` ignores the carried balance and drives the legend's
totals cell. Both keep those meanings exactly. A treasury makes `satisfaction` *better* than
`flow_satisfaction`; a waste stock makes it *worse*. One structure, opposite signs, no new field.

**`flow_satisfaction` must keep reading `supplied` alone.** It answers "is my per-tick economy
balanced", and a city whose emissions match its capacity has a balanced economy even while
digging out of a backlog — that is precisely the state a player needs to distinguish.

## 3. Persistence — the outage-class risk

`CityMap` gains `waste_stock: 0.0`, and `CityMap` **is persisted**: both adapters write
`:erlang.term_to_binary(city_map, [:compressed])` and decode with `:safe`. A payload written
before this change decodes to a struct with no `:waste_stock` key, so `city_map.waste_stock`
raises `KeyError` — a crash-loop on every stored city. That is the shape of the 2026-08-05
production 500.

`SnapshotVocabulary.modernize/1` is the existing remedy and already runs on both adapters
immediately after decode. It currently reads:

```elixir
def modernize(%{nodes: nodes} = city_map) when is_map(nodes) do
  %{city_map | nodes: Map.new(nodes, fn {id, node} -> {id, rename_type(node)} end)}
end
```

The update syntax `%{map | key: value}` **requires the key to already exist**, so the new field
cannot be added that way. It must go through `Map.put_new/3`, which works on any map:

```elixir
def modernize(%{nodes: nodes} = city_map) when is_map(nodes) do
  city_map
  |> Map.put_new(:waste_stock, 0.0)
  |> Map.put(:nodes, Map.new(nodes, fn {id, node} -> {id, rename_type(node)} end))
end
```

**Both committed fixtures already exercise the missing-key path for free.**
`test/support/fixtures/city_snapshot_pre_transit_hub_rename.bin` and
`city_snapshot_vocabulary_coverage.bin` were written long before this field existed. They are
the regression test — but only if a test *reads* `waste_stock` after `modernize/1`. A test that
merely decodes them passes whether or not the migration exists, so §6 requires the assertion be
on the field's value.

This is a field addition, not an atom rename, so no `@node_type_renames` entry is owed and
`@modules` does not change.

### The other direction: rollback and version skew

§3 above covers old payload → new code. **The reverse is the more dangerous direction and this
spec originally missed it.** Once this release checkpoints a city, the stored term contains the
atom `:waste_stock`. That atom does not exist on `main` — verified, zero references — and
`:erlang.binary_to_term/2` with `:safe` *will not create it*. So an older binary reading a
snapshot written by this one fails, and the two adapters fail differently:

| adapter | behaviour on rollback |
|---|---|
| `SnapshotStore` (server) | `decode/3` calls `binary_to_term([:safe])` with no rescue → `ArgumentError` → **the engine crash-loops**, the 2026-08-05 shape exactly |
| `FileSnapshotStore` (desktop) | `safe_binary_to_term/1` is rescued and falls to `_unusable -> :error` → starts an **empty city**, and the stale envelope tick can then block later saves |

**The only way to make rollback safe is a two-release protocol:** ship a release that interns
`:waste_stock` without writing it, make that the minimum rollback target, then ship the writer.
A single release cannot be rollback-safe, because the atom has to already exist in the binary
doing the reading and no change here can retroactively put it there.

**Decision: ship as one release, and make the constraint visible rather than silent.** This is a
single-host deploy with no documented rollback practice, and `docs/deploying.md` already carries
the sibling trap ("The other trap: renaming a node type"). The plan therefore:

* adds `:waste_stock` to `SnapshotVocabulary`'s interned vocabulary, so the *reading* side is
  explicit about the atom rather than relying on `CityMap` happening to be loaded;
* adds an entry to `docs/deploying.md` naming this commit as the minimum rollback target and
  stating that rolling back past it strands every city written since;
* is sequenced so the persistence commit lands first, giving a natural two-release boundary for
  anyone who wants one.

Desktop version skew is the residual risk and is not fully solved: a user who downgrades their
build loses their city to an empty grid rather than a crash. Recorded, not mitigated.

## 4. Unfloored decay, and what it costs

`satisfaction` is not floored at zero. With a stock large enough, `available` goes negative,
`satisfaction` goes negative, and `health_delta/1` — which is `−(1 − worst) × @decay_per_tick` —
returns more than `@decay_per_tick`.

**`@decay_per_tick` therefore stops being a maximum and becomes a coefficient.** Its value does
not change; its meaning does. Derived, not measured: at demand 52, supply 56 and a stock of 200,
`available` is −144, `satisfaction` is −2.77, and the per-tick loss is 22.6 rather than 6.0 — so
a node at full health reaches zero in 5 ticks instead of 17. The plan must confirm this against
the running engine rather than inheriting the arithmetic.

This was chosen deliberately over flooring satisfaction at 0.0. The consequence accepted with it
is §5: collapse timings in `docs/PLAYING.md` were all measured under a 6.0/tick ceiling that no
longer holds wherever waste is the binding constraint.

**Nothing else assumes `satisfaction ∈ [0, 1].`** Audited: `worst_satisfaction/2` takes a `min`
and is fine with negatives; `stalled?/2` tests `< 1.0` and is fine; `CityEngine`'s
`@critical_satisfaction 1.0` filter and its `sort_by` both behave correctly and put waste first,
which is right. The only two readers that misbehave are display strings, handled in §5.

### `stalled?/2` must gain a clause, or a backlogged city freezes forever

An earlier draft of this spec claimed accumulation only falsifies a comment. That was wrong, and
the error is instructive: the symptom was visible — *"the next tick is identical"* becomes true
of the nodes and false of the city — and the draft concluded "reword the comment" instead of
"the predicate is now wrong".

`CityEngine.handle_info/2` has this clause:

```elixir
def handle_info({:tick, _clock_pulse}, %{metrics: %{stalled: true}} = state) do
  {:noreply, state}
end
```

A stalled city runs **no ticks at all**. Un-stalling requires some node to reach
`worst_satisfaction >= 1.0`. With a backlog, waste satisfaction stays below 1.0 for every
waste-consuming node until the stock drains — and the stock drains only on a tick. So a stalled
city holding a landfill can never leave that state: demolishing every emitter does not help,
because the demolition recomputes metrics but the stock is unchanged and still suppresses
satisfaction. The city is frozen permanently, with a treasury the player cannot spend their way
out with.

**`stalled?` therefore takes the stock as a third argument and requires it to be at a fixpoint
too:**

```elixir
defp stalled?([], _stats, _stock), do: false

defp stalled?(nodes, stats, stock) do
  Enum.all?(nodes, fn node ->
    node.health == @min_health and worst_satisfaction(node, stats) < 1.0
  end) and Map.fetch!(stats, :waste).deficit >= stock
end
```

**The comparator is `>=`, not `==`, and the difference decides whether `game_over?/1` still
fires.** What the predicate has always meant in substance is *no node can recover*, which the old
"next tick is identical" phrasing happened to coincide with. Against a moving stock the three
cases separate:

| next deficit vs stock | landfill | can any node recover? | stalled |
|---|---|---|---|
| `deficit > stock` | growing | no, and it worsens every tick | **true** |
| `deficit == stock` | settled | no | **true** |
| `deficit < stock` | draining | yes, once it clears | **false** |

An `==` test would call the *growing* case not-stalled, so a city drowning in waste would tick
forever, never be stalled, and therefore never satisfy `game_over?/1 = stalled and bankrupt` —
turning an unmistakably finished city into one the UI never calls finished.

Worked, the rescue case: a dead city with stock 60 and every emitter demolished has capacity 40
and emissions 0, so the next deficit is `max(0, 0 − 40 + 60) = 20 < 60` — draining, not stalled,
ticks resume, the stock runs 60 → 20 → 0, and the nodes heal from there.

Worked, the drowning case: five dead houses emit 50 against the baseline's 40, so the next
deficit is `stock + 10 > stock` — growing, stalled, and `game_over?/1` behaves exactly as it does
today.

## 5. Presentation

**A `Landfill` line in the metrics panel**, the counterpart to `Treasury`:

```elixir
<p id="metrics-landfill">Landfill: {trunc(@metrics.waste_stock)}</p>
```

`trunc/1` matches the treasury line's flooring. `SimulationMetrics` gains a `waste_stock` field
so the LiveView never sees a `CityMap` — the boundary graph bars `ArmchairMetropolistWeb` from
`Domain.Services`, and every figure the UI needs travels on the metrics struct.

**Two display strings clamp negative satisfaction at zero**, in the view layer only, leaving the
domain value untouched:

| site | today | with a backlog | after |
|---|---|---|---|
| `SimulatorLive.tightest_resource/1` | `Tightest: waste 34%` | `waste −280%` | `waste 0%` |
| `CityEngine`'s deficit notification | `waste at 34% of demand` | `−280% of demand` | `0% of demand` |

`0% of demand` beside `Landfill: 78` is legible; `−280% of demand` is not. The domain keeps the
signed value because `sort_by` needs it to rank waste against other shortfalls correctly.

## 6. What must be re-measured

**Not the reference tables.** Accumulation only bites where a deficit exists, and every
configuration the generated blocks describe is deficit-free by construction. The opening
sequence runs waste at `28/48`, `38/48`, `38/56`, `52/56` — demand under supply at every stage —
so `opening`, `opening_pace`, `opening_wall`, `capacities`, `baseline`, `production`,
`consumption` and `costs` are all unaffected. `docs/PLAYING.md` should regenerate byte-identical
in its generated blocks.

**The criterion for a prose claim being at risk** is sharp: a documented scenario changes only if
its health-weighted waste emissions exceed `40 + 90 × industrial + 8 × parks`. Emissions per
type are `commercial 14`, `power_plant 12`, `residential 10`, `water_plant 6`, `transit_hub 2`.
So the free baseline alone absorbs **three** power plants (36), **four** houses (40, exactly at
the line and still deficit-free), or **two** shops (28) — and the fourth plant, fifth house or
third shop is where a stock first appears.

Applying that criterion to every measured tick-count in the guide:

| claim | emitters | verdict |
|---|---|---|
| `:54` "a lone power plant is offline in 14 ticks and dead in 17" | 12 of 40 | **unaffected** — killed by labour, not waste |
| `:237` "a producer on an empty grid dies in 17 ticks" | ≤ 14 of 40 | **unaffected**, same reason |
| `:174` the opening pacing bound, 4 ticks between placements | never in deficit | **unaffected** |
| `:408` "two houses recover to 100 health within 100 ticks" | 20 of 40 | **unaffected** |
| `:102` the "residential, no support" table | 10 per house — crosses 40 at five | **must be re-measured** |
| `:273` "still 0.0 after 150 ticks" | depends on the board | **must be re-checked** |
| `:292` "within 100 ticks" | depends on the board | **must be re-checked** |

The plan must measure each of the last three against the running engine rather than reasoning
about them, and rewrite the rescue section's advice ordering: demolishing an emitter now drains
the backlog as well as cutting the flow, which strengthens advice the guide already gives.

## 7. Correcting §10 of the predecessor spec

§10 gave three reasons to defer. Recorded here because two were wrong and a plan written from
§10 alone would budget for work that does not exist:

1. **"It creates positive feedback"** — true, and intended.
2. **"It breaks `stalled?/2`"** — false. §4 shows the fixpoint is reinforced, not broken. One
   comment sentence needs rewording.
3. **"It invalidates the guide's measured figures, including the opening sequence, its pacing
   bound, and the capacities block"** — false for all three named artefacts, which are
   deficit-free by construction. §6 gives the real list, which is three prose claims.

§10 also predicted `stats.deficit` would be the field this builds on. That was right, and §2
shows it is exact rather than approximate.

## 8. Accepted consequences

**The spiral is real and can outrun a player.** A city that loses its `industrial` block at
emissions 52 accumulates 26 per tick and passes satisfaction 0.0 within three ticks, after which
every node consuming waste handling takes more than the old maximum decay. This is the intended
teeth of the mechanic and the reason it was deferred rather than shipped alongside the polarity
rename.

**Recovery is possible but not always affordable, and only because §4 fixes `stalled?`.** The
stock drains at `capacity − emissions`, so the exit is to build `industrial` or demolish
emitters — but a city deep enough in the spiral may be bankrupt before it can do either, which
is the existing `game_over?/1` condition reached by a new route. No change to that predicate is
needed. **Without §4's third clause this sentence would be false**: the engine skips ticks for a
stalled city, so a backlogged one could never drain and no amount of money would rescue it.

**A backlog with no emitters left reads as fully satisfied.** `satisfaction/2` returns `1.0` when
`demanded == 0.0`, so a city bulldozed to nothing but a landfill shows "All resources supplied"
while the stock drains. Correct in substance — no node consumes waste handling, so none is
harmed — and the `Landfill` line is what tells the player the backlog is still there. Recorded so
nobody later "fixes" the guard.

**Two resources now behave differently despite sharing a polarity.** Waste is a stock, traffic a
flow. The guide must say so plainly; §1 records why.
