# Capacity/load rename Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the per-type resource vocabulary from `production`/`consumption` to `capacity`/`load`, so the domain reads correctly for negative resources without a comment explaining that a "production" entry can mean removal.

**Architecture:** A pure refactor — no behaviour changes, no table values move, no test expectations change. Decomposed by **identifier**, not by file: `Node.production/1` → `Node.capacity/1` breaks every caller the moment it lands, so all callers of one identifier are a single atomic commit. A file-by-file split cannot compile in between.

**Tech Stack:** Elixir, Phoenix LiveView 1.2, ExUnit.

**Spec:** `docs/superpowers/specs/2026-08-07-negative-resource-polarity-design.md` §9. Two scope decisions were settled after that section was written and **override it**: the rename stops at the per-type layer (§9 implies nothing about the aggregate; see Global Constraints), and the guide's generated-block markers keep their current names.

## Global Constraints

- **This is a rename. No behaviour changes.** No value in any table moves. No test's expected value changes. `mix test` must report the **same 375 passing** at every commit — a changed count means something other than a rename happened.
- **The rename stops at the per-type layer.** These rename:
  `Node.production/1`→`capacity/1`, `Node.consumption/1`→`load/1`, `@production_table`→`@capacity_table`, `@consumption_table`→`@load_table`, `Node.effective_production/1`→`effective_capacity/1`, and `SimulationMetrics.type_stats`'s `rated_production`→`rated_capacity`, `actual_production`→`actual_capacity`, `consumption`→`load`.
- **These do NOT rename**, because they describe supply and demand *for the service*, which already reads correctly for both polarities (houses demand waste handling; industrial supplies it): `SimulationCalculator.total_supply/1`, `total_demand/1`, `resource_stats/1`'s `supplied` / `carried` / `demanded` / `deficit` / `satisfaction` / `flow_satisfaction` keys, `baseline_capacity/0`, and the totals row header `demanded/supplied · met this tick`.
- **The guide's generated-block markers stay.** `<!-- generated:production -->` and `<!-- generated:consumption -->` in `docs/PLAYING.md`, the `"production"` / `"consumption"` keys in `PlayingGuide.blocks/0`, and the function names `production_block/0` / `consumption_block/0` that produce them are anchors, not vocabulary. Leave all of them. `docs/PLAYING.md` must come out of this plan **byte-identical** — its headings were already made polarity-neutral ("Per-block effect, scaled by health").
- **NEVER do this rename with `sed`, a global find-and-replace, or an IDE "rename in comments".** The word `production` has three senses in this repo and only one of them is ours. Task 3 carries the full do-not-touch list.
- **No snapshot migration.** `SnapshotVocabulary`'s reachable-module set is `[CityMap, Node]` and the persisted `Node` struct is `[:id, :x, :y, :type, :health, :status]`. `SimulationMetrics` is rebuilt every tick and never persisted, so its field renames touch no stored term. Task 2 verifies this rather than assuming it.
- Run `mix test` before every commit. A pre-commit hook runs `mix precommit`; do not bypass it with `--no-verify`.

---

### Task 1: The `Node` layer — `capacity`, `load`, `effective_capacity`

**Files:**
- Modify: `lib/armchair_metropolist/domain/entities/node.ex` — `@production_table`, `@consumption_table`, `production/1`, `consumption/1`, `effective_production/1`
- Modify: `lib/armchair_metropolist/domain/services/simulation_calculator.ex` — 3 call sites
- Modify: `lib/armchair_metropolist/domain/entities/simulation_metrics.ex` — 3 call sites
- Modify: `lib/armchair_metropolist_web/live/simulator_live.ex` — 5 call sites
- Modify: `lib/armchair_metropolist/infrastructure/persistence/snapshot_vocabulary.ex:75` — one moduledoc reference
- Modify: `test/support/playing_guide.ex` — `production_of/1` and one `Node.consumption/1` call
- Test: `test/armchair_metropolist/domain/entities/node_test.exs`, `test/armchair_metropolist/domain/domain_properties_test.exs`

**Interfaces:**
- Consumes: nothing.
- Produces: `Node.capacity(node_type) :: %{resource => float()}`, `Node.load(node_type) :: %{resource => float()}`, `Node.effective_capacity(node) :: %{resource => float()}`. Task 2 calls all three.

- [ ] **Step 1: Find every call site before changing anything**

```bash
rg -n "Node\.production|Node\.consumption|@production_table|@consumption_table|effective_production|production_of" lib/ test/
```

Expect roughly 50 hits across 10 files. Write the list into your report — you will check against it in Step 6.

- [ ] **Step 2: Rename in `node.ex`**

Rename the two module attributes and the three public functions. The attribute definitions become:

```elixir
  # Capacity tables — the health-scaled side of the ledger.
  @capacity_table %{
```

```elixir
  # Load tables — the side that is never scaled by health.
  @load_table %{
```

The accessors become `capacity/1`, `load/1` and `effective_capacity/1`. Update each `@doc` and `@spec` to match. Two comments inside this file mention the old names and must move with them:

- the `@negative_resources` comment says "a production-table entry is *removal* capacity and a consumption-table entry is *emission*". Under the new names that sentence is almost tautological, which is the point of the rename — reword it to "a capacity-table entry is *removal* capacity and a load-table entry is *emission*", keeping the rest of the paragraph (the health-scaling rationale) exactly as it is.
- `types/0`'s doc says "Derived from the production table keys" → "capacity table keys".

**Do not touch** the `defstruct` line, the persistence comment above it, `@construction_cost_table`, `@demolition_cost`, or any numeric value.

- [ ] **Step 3: Update the five caller files**

Mechanical: `Node.production(` → `Node.capacity(`, `Node.consumption(` → `Node.load(`, `Node.effective_production(` → `Node.effective_capacity(`. In `test/support/playing_guide.ex` also rename the private wrapper `production_of/1` → `capacity_of/1` and its three call sites.

In `snapshot_vocabulary.ex`, the moduledoc at line 75 reads "where `Node.production/1` raises on them" → "where `Node.capacity/1` raises on them". **That file also contains the phrase "The 2026-08-05 production outage" at line 33 — that is the deployment environment, not this concept. Do not touch it.**

Leave `production_block/0` and `consumption_block/0` in `playing_guide.ex` named as they are; they are named for the markers they emit (Global Constraints).

- [ ] **Step 4: Update the two test files that call these functions directly**

`node_test.exs` has 28 hits, including a `describe "production/1 and consumption/1"` block and a `describe "effective_production/1"` block — rename both describe strings to match the new function names. `domain_properties_test.exs` has 1.

Assertion *values* do not change. If you find yourself editing a number, stop and report BLOCKED.

- [ ] **Step 5: Compile and run the suite**

```bash
mix test
```

Expected: **375 passed**, exactly as before. A different count means this was not a pure rename.

- [ ] **Step 6: Confirm no old identifier survives**

```bash
rg -n "Node\.production|Node\.consumption|@production_table|@consumption_table|effective_production|production_of" lib/ test/
```

Expected: **no output.**

Before trusting that emptiness, prove the grep can fire: run the same command against `main` (`git stash && rg … ; git stash pop`, or `git grep <pattern> main -- lib test`) and confirm it returns the ~50 hits from Step 1. An absence-proving grep is an instrument, and silence from a pattern that never matches looks identical to success.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor: rename Node's production/consumption to capacity/load"
```

---

### Task 2: `SimulationMetrics.type_stats` — `rated_capacity`, `actual_capacity`, `load`

**Files:**
- Modify: `lib/armchair_metropolist/domain/entities/simulation_metrics.ex` — the `type_stats` typedoc and type, `build_by_type/1`, `sum_actual_production/2`
- Modify: `lib/armchair_metropolist_web/live/simulator_live.ex` — `total_cell/4`'s three `Map.get(stats, ...)` reads and the `{:park, :labour}` clause's `stats.consumption`
- Test: `test/armchair_metropolist/domain/entities/simulation_metrics_test.exs` (8 hits), `test/armchair_metropolist_web/live/simulator_live_test.exs` (fixtures at ~1035 and ~1050)

**Interfaces:**
- Consumes: `Node.capacity/1`, `Node.load/1`, `Node.effective_capacity/1` from Task 1.
- Produces: `type_stats` maps keyed `count`, `rated_capacity`, `actual_capacity`, `load`. Nothing after this task consumes them.

- [ ] **Step 1: Confirm the fields are not persisted**

```bash
rg -n "@modules" -A 4 lib/armchair_metropolist/infrastructure/persistence/snapshot_vocabulary.ex
```

Expected: `[ArmchairMetropolist.Domain.Entities.CityMap, ArmchairMetropolist.Domain.Entities.Node]` — `SimulationMetrics` absent, so no atom in it reaches a stored term and no `@node_type_renames` entry is needed. Record this output in your report. If `SimulationMetrics` IS listed, stop and report BLOCKED: the rename would then be a data migration.

- [ ] **Step 2: Rename the three fields in `simulation_metrics.ex`**

In the `@type type_stats` definition:

```elixir
  @type type_stats :: %{
          count: non_neg_integer(),
          rated_capacity: %{Node.resource() => float()},
          actual_capacity: %{Node.resource() => float()},
          load: %{Node.resource() => float()}
        }
```

In `build_by_type/1`:

```elixir
       %{
         count: length(of_type),
         rated_capacity: scale(Node.capacity(type), length(of_type)),
         actual_capacity: sum_actual_capacity(type, of_type),
         load: scale(Node.load(type), length(of_type))
       }}
```

Rename the private `sum_actual_production/2` → `sum_actual_capacity/2`, and update its comment "Keyed off the type's *base* production table" → "*base* capacity table".

The `type_stats` typedoc says "where that node type's base tables mention the resource" — that sentence is already name-neutral; leave it.

- [ ] **Step 3: Update the LiveView's four reads**

In `total_cell/4`'s general clause:

```elixir
    produced = Map.get(stats.rated_capacity, resource)
    actual = Map.get(stats.actual_capacity, resource)
    consumed = Map.get(stats.load, resource)
```

and in the `{:park, :labour}` clause, `Map.get(stats.consumption, :labour, 0.0)` → `Map.get(stats.load, :labour, 0.0)`.

**Leave the local variable names `produced`, `actual` and `consumed` alone.** They are internal to the function, they are passed to `net/3` whose parameters are named `produced` and `consumed`, and renaming them would widen this task into `net/3`'s signature for no gain. Only the `stats.*` field reads change.

- [ ] **Step 4: Update the two test files**

`simulation_metrics_test.exs` reads `by_type.power_plant.rated_production.power` and similar in 8 places — rename the field accesses only. `simulator_live_test.exs`'s two fixtures (`metrics_with_power_production/2` and `metrics_with_industrial_waste/2`) build maps with `rated_production:` / `actual_production:` / `consumption:` keys — rename those keys, and rename the first fixture to `metrics_with_power_capacity/2` along with its two call sites.

Assertion values do not change.

- [ ] **Step 5: Run the suite**

```bash
mix test
```

Expected: **375 passed**.

- [ ] **Step 6: Confirm no old field name survives**

```bash
rg -n "rated_production|actual_production|sum_actual_production|metrics_with_power_production|stats\.consumption" lib/ test/
```

Expected: no output.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor: rename type_stats fields to capacity and load"
```

---

### Task 3: Prose triage

**Files:**
- Modify: comments and test names across `lib/` and `test/` — the exact list is in Step 2
- Do NOT modify: `docs/PLAYING.md` (must stay byte-identical), and every site in Step 1's do-not-touch list

**Interfaces:**
- Consumes: the vocabulary from Tasks 1 and 2.
- Produces: nothing.

**Why this is its own task.** The identifiers are done; what remains is prose, and prose is where the word `production` collides with two unrelated meanings. This project treats a false comment as a real defect, so the triage is the deliverable.

- [ ] **Step 1: Read the do-not-touch list**

Every one of these uses `production` in a sense that has nothing to do with the domain. **Leave all of them exactly as they are.** They are listed with their sense so you can recognise the pattern if you find more:

| file:line | text | sense |
|---|---|---|
| `snapshot_vocabulary.ex:33` | "The 2026-08-05 production outage was exactly this." | deployment environment |
| `lib/mix/tasks/version.set.ex:20` | "A production Burrito binary unpacks…" | deployment environment |
| `lib/armchair_metropolist_web/endpoint.ex:59` | "When code reloading is disabled (e.g., in production)" | deployment environment |
| `simulator_live.ex:362` | "the same line at a production-length host" | a real deployed hostname |
| `simulator_live.ex:401` | "506px at a production-length one" | a real deployed hostname |
| `simulator_live_test.exs:10` | "a stable constant with no production reader" | the non-test code path |
| `simulator_live_test.exs:55` | "mounts two more cities through the production…" | the non-test code path |
| `endpoint_session_test.exs:38` | "through the production `ensure_started/1` path" | the non-test code path |

If you are unsure about a hit not on this list, leave it and flag it in your report. A false negative costs a follow-up comment; a false positive corrupts a sentence about a production outage.

- [ ] **Step 2: Rewrite these, which ARE the domain sense**

| file:line | change |
|---|---|
| `simulator_live.ex:788` | "labour effect is in neither production table nor consumption table" → "neither capacity table nor load table" |
| `simulator_live.ex:798` | "`consumption` is already scaled by count in `build_by_type/1`" → "`load` is already scaled…" |
| `simulator_live_test.exs:400` | "the `+120` and `+360` figures two of these tests pin are power_plant production" → "…are power_plant capacity" |
| `simulator_live_test.exs:575` | "actual production drifts below rated" → "actual capacity drifts below rated" |
| `simulator_live_test.exs:847` | test name "render through the ordinary consumption path" → "the ordinary load path" |
| `simulator_live_test.exs:1032` | "actual production is whatever health decay happens to have left" → "actual capacity is…" |
| `simulator_live_test.exs:1117` | "`Node.types/0` is `Map.keys/1` over the production table" → "over the capacity table" |
| `simulation_metrics_test.exs:109` | test name "rated production is count x base and ignores health" → "rated capacity is…" |
| `simulation_metrics_test.exs:120` | test name "actual production is health-scaled and diverges from rated" → "actual capacity is…" |
| `simulation_metrics_test.exs:121-122` | "production scales with health, consumption does not" → "capacity scales with health, load does not" |
| `simulation_metrics_test.exs:138` | test name "consumption is count x base and does not scale with health" → "load is count x base…" |
| `playing_guide_test.exs:11` | "Regenerate after changing a production, consumption or health rule" → "a capacity, load or health rule" |
| `playing_guide_test.exs:44` | "A production, consumption or health rule has changed" → "A capacity, load or health rule has changed" |
| `simulation_metrics.ex:158-159` | "production scales with health and consumption does not" → "capacity scales with health and load does not" (the phrase spans a line break — "…one figure: production" / "scales with health and consumption does not") |
| `simulation_calculator.ex:8-9` | "every node's *health-scaled* production of `r`" → "*health-scaled* capacity for `r`" (also spans a line break) |
| `simulation_calculator.ex:14` | "every node's *full* consumption of `r`" → "every node's *full* load for `r`" |
| `simulation_calculator.ex:254` | "Full consumption from every node, regardless of that node's health." → "Full load from every node, …" |

**One nearby phrase is plain English, not the domain term — leave it.** `simulation_calculator.ex:12` reads "so parks raise the workforce their housing supplies without **producing** labour themselves". That is the ordinary verb describing the amenity mechanic, four lines from a sentence that *does* use the domain term. It stays.

`playing_guide_test.exs:83,90,92,93` reference `PlayingGuide.blocks()["production"]` and a test named "the generated production block…" — those name the **marker**, which stays. Leave them.

- [ ] **Step 3: Run the suite**

```bash
mix test
```

Expected: **375 passed**. Test names changed but no test was added or removed.

- [ ] **Step 4: Confirm `docs/PLAYING.md` is untouched**

```bash
git diff --stat docs/PLAYING.md
```

Expected: **no output.** The guide's headings were already made polarity-neutral and its generated blocks are driven by table *values*, which did not move. If the guide shows a diff, a table value changed — stop and report BLOCKED.

- [ ] **Step 5: Regenerate the guide as a check that nothing drifted**

```bash
REGENERATE_PLAYING_GUIDE=1 mix test test/docs/playing_guide_test.exs
git diff --stat docs/PLAYING.md
```

Expected: the regenerate reports the guide was already current, and the diff is still empty. This is the cheap check that the rename did not change a single rendered figure.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor: move comments and test names to the capacity/load vocabulary"
```

---

## Final verification

- [ ] **The vocabulary is gone from identifiers:**

```bash
rg -n "Node\.production|Node\.consumption|@production_table|@consumption_table|effective_production|rated_production|actual_production|production_of|sum_actual_production" lib/ test/
```

Expected: no output.

- [ ] **The do-not-touch sites are intact:** confirm `snapshot_vocabulary.ex` still says "production outage", `endpoint.ex` still says "in production", and `simulator_live.ex` still says "production-length host". A rename that ate these is worse than not renaming at all.

- [ ] **Behaviour is unchanged:** `git diff main --stat` shows no change to any numeric literal, and `mix test` reports 375 passed.

- [ ] **`docs/PLAYING.md` is byte-identical to `main`:** `git diff main -- docs/PLAYING.md` is empty.
