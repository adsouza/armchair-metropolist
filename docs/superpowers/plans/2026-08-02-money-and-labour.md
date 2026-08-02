# Money and Labour Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two resources — `labour`, produced by residential and required by industrial and commercial, and `money`, a carried-over treasury produced by commercial and residential and consumed by water plants, road hubs and parks.

**Architecture:** Both ride the existing supply/demand/satisfaction machinery in `SimulationCalculator`, so no new failure path is introduced: a shortfall decays the consuming nodes exactly as a water shortage does. Money is the sole exception — its unspent supply survives the tick boundary, expressed as a new `carried` field in `resource_stats` and a `money` field on `CityMap`.

**Tech Stack:** Elixir 1.20 / OTP 29, Phoenix LiveView, ExUnit, `boundary` for layering, Tailwind v4 + daisyUI.

**Spec:** `docs/superpowers/specs/2026-08-02-money-and-labour-design.md`

## Global Constraints

- Resource display order is exactly `[:power, :water, :waste, :traffic, :labour, :money]`.
- Table values, verbatim: `commercial` produces `money 30.0` and consumes `labour 8.0`; `residential` produces `money 1.0` and `labour 4.0`; `industrial` consumes `labour 12.0`; `water_plant` consumes `money 5.0`; `road_hub` consumes `money 4.0`; `park` consumes `money 3.0`.
- Baseline capacity gains `labour: 0.0` and `money: 0.0` — explicit zeros, never omitted.
- `CityMap.money` defaults to `500.0`.
- The balance floors at zero. Debt is not modelled.
- Every figure in the tables is a whole number. Do not introduce a fractional value: `signed/1` rounds, and a decimal would require a second precision rule plus a matching change to the `rated → actual` comparison.
- `mix check` must pass at the end of every task: `format --check-formatted`, `compile --force --warnings-as-errors` (this is what enforces `boundary`), `sobelow`, `deps.audit`, `test --cover` at a 90% threshold.
- LiveView assertions use `element/2` / `has_element?/2`, never `html =~` (`AGENTS.md:376`).
- Every new test must be mutation-verified: break the code it covers, confirm *that* test goes red, restore. A test you have not seen fail is not a test.
- `docs/PLAYING.md` is generated. Never hand-edit it. Regenerate with
  `REGENERATE_PLAYING_GUIDE=1 mix test test/docs/playing_guide_test.exs`.

---

### Task 1: The labour resource

Labour first, and alone, because it needs no new state — it is purely additive within the existing machinery. Money needs a field on `CityMap` and a change to the tick, so it comes later.

**Files:**
- Modify: `lib/armchair_metropolist/domain/entities/node.ex` — `@resources`, `@production_table`, `@consumption_table`
- Modify: `lib/armchair_metropolist/domain/services/simulation_calculator.ex` — `@baseline_capacity`
- Modify: `test/armchair_metropolist/domain/entities/node_test.exs:34` and the `production/1 and consumption/1` block
- Modify: `test/armchair_metropolist/domain/services/simulation_calculator_test.exs:47` (`baseline_capacity/0` exact-map assertion)
- Modify: `test/support/playing_guide.ex` — `@resources`
- Test: `test/armchair_metropolist/domain/services/simulation_calculator_test.exs`

**Interfaces:**
- Produces: `Node.resources/0` returning `[:power, :water, :waste, :traffic, :labour]` at the end of this task (money is appended in Task 4). `Node.production(:residential) == %{labour: 4.0}`, `Node.consumption(:industrial)` gains `labour: 12.0`, `Node.consumption(:commercial)` gains `labour: 8.0`.

- [ ] **Step 1: Write the failing test** — in `simulation_calculator_test.exs`, inside `describe "resource_stats/1"`:

```elixir
# The housing requirement, stated directly rather than inferred from the tables.
# An industrial block with nobody to staff it is the city shape this resource
# exists to forbid.
test "industry with no housing has no labour and decays at the full rate" do
  map = map_with([Node.new(0, 0, :industrial)])
  stats = Calc.resource_stats(map)

  assert stats.labour.demanded == 12.0
  assert stats.labour.supplied == 0.0
  assert stats.labour.satisfaction == 0.0

  {advanced, _delta} = Calc.advance_tick(map)
  industrial = CityMap.get_node(advanced, 0, 0)
  # -(1 - 0.0) * 6.0 from a starting 100.0
  assert_in_delta industrial.health, 94.0, 0.001
end

test "enough housing staffs the industry and stops the decay" do
  # 3 residential supply 12 labour, exactly the industrial block's demand.
  map = map_with([Node.new(0, 0, :industrial) | for(x <- 1..3, do: Node.new(x, 0, :residential))])
  stats = Calc.resource_stats(map)

  assert stats.labour.supplied == 12.0
  assert stats.labour.satisfaction == 1.0

  {advanced, _delta} = Calc.advance_tick(map)
  assert CityMap.get_node(advanced, 0, 0).health == 100.0
end
```

- [ ] **Step 2: Run them and watch them fail**

Run: `mix test test/armchair_metropolist/domain/services/simulation_calculator_test.exs -k labour`
Expected: FAIL — `stats.labour` raises `KeyError`, because `:labour` is not in the vocabulary yet.

- [ ] **Step 3: Add labour to the vocabulary and the tables**

In `node.ex`, `@resources` becomes `[:power, :water, :waste, :traffic, :labour]`, and `@type resource :: :power | :water | :waste | :traffic | :labour`. Then:

```elixir
@production_table %{
  power_plant: %{power: 120.0},
  water_plant: %{water: 100.0},
  industrial: %{waste: 90.0},
  road_hub: %{traffic: 60.0},
  residential: %{labour: 4.0},
  commercial: %{},
  park: %{waste: 8.0}
}

@consumption_table %{
  power_plant: %{water: 20.0, waste: 12.0, traffic: 3.0},
  water_plant: %{power: 25.0, waste: 6.0, traffic: 2.0},
  industrial: %{power: 40.0, water: 25.0, traffic: 8.0, labour: 12.0},
  road_hub: %{power: 8.0, waste: 2.0},
  residential: %{power: 15.0, water: 12.0, waste: 10.0, traffic: 6.0},
  commercial: %{power: 22.0, water: 8.0, waste: 14.0, traffic: 9.0, labour: 8.0},
  park: %{water: 18.0, traffic: 2.0}
}
```

In `simulation_calculator.ex`:

```elixir
@baseline_capacity %{power: 40.0, water: 40.0, waste: 40.0, traffic: 40.0, labour: 0.0}
```

The zero is the mechanic, not a placeholder — say so in a comment. Add one above the entry: `# No free workers: labour comes only from housing, which is the point of the resource.`

- [ ] **Step 4: Update the two pinning tests**

`node_test.exs:34` — rename the test (it says "the four resources") and assert the five-element list. In the `production/1 and consumption/1` block, `Node.production(:residential)` is now `%{labour: 4.0}`, and the `industrial` / `commercial` consumption maps gain their labour keys.

`simulation_calculator_test.exs:47` — the exact-map assertion gains `labour: 0.0`. Rename the test: it no longer "supplies 40 of every resource".

- [ ] **Step 5: Run the whole suite and triage**

Run: `mix test`
Expected: the two new tests pass. `test/docs/playing_guide_test.exs` **fails** — that is Step 6. If anything else fails, stop and report: no other fixture should be affected, since `sustainable_city` has no labour consumer and `sub_rounding_city` has none either.

After Step 6, the regenerated capacities table should report bands of 3–5, 3–9 and 6–15 for the
three existing support sets. Those are solved from the tables at full health, so the simulated
figures may differ by a block where a city decays slowly rather than failing outright — but a
band that is empty, or wildly different, means something is wrong rather than merely dynamic.
Report the measured numbers either way.

- [ ] **Step 6: Fix the guide generator's search, then regenerate**

`max_residential/4` walks `r` upward from 1 and halts on the first unsustainable value, which assumes the predicate is true-then-false. Labour inverts the low end: at `r = 1` an industrial block has 4 workers against a demand of 12, starves, and the search halts at zero. It must report the sustainable *range* instead:

```elixir
  # Labour makes the low end fail too — too few residents cannot staff the
  # industry — so the sustainable set is a band, not a prefix, and the old
  # `reduce_while` that halted on the first failure returned 0. Scan the whole
  # range and report both ends.
  #
  # Returns {min, max}, or nil when no residential count is sustainable.
  defp residential_range(pp, wp, ind, rh) do
    sustainable =
      for r <- 1..40,
          city =
            city_with(
              power_plant: pp,
              water_plant: wp,
              industrial: ind,
              road_hub: rh,
              residential: r
            ),
          final = Enum.reduce(1..120, city, fn _, c -> elem(Calc.advance_tick(c), 0) end),
          Calc.metrics(final).avg_health >= 99.9,
          do: r

    case sustainable do
      [] -> nil
      rs -> {Enum.min(rs), Enum.max(rs)}
    end
  end
```

**Scan the full range; do not bisect.** A two-sided binary search would find the same band in a
fraction of the simulations, and it would be wrong the first time the band is not contiguous — a
failure that shows up as a plausible wrong number in a published document, not as a test failure.
The linear scan needs no contiguity assumption. Solved against the tables, the bands *are*
contiguous today — 3–5, 3–9 and 6–15 for this task's three sets — but that is a property of the
current numbers, not of the model, and the guide is regenerated whenever those numbers change.

The cost is affordable: the guide test runs in 0.07s today, and replacing an early exit at about
`max + 1` iterations with a fixed 40 is roughly 2.5–7× more simulation over somewhat larger
cities. Sub-second. Do not trade the correctness for it.

`capacities_block/0` gains a "min residential" column beside the max, and must render a set with
no sustainable count as an explicit failure rather than a blank — a silently empty row reads like
a successful regeneration. Task 4 widens this to `residential_range/5` with a commercial count.

Also add `:labour` to `@resources` in `playing_guide.ex`.

Then regenerate and inspect the diff — the consumption table gains a labour column and the capacities table's numbers move:

```bash
REGENERATE_PLAYING_GUIDE=1 mix test test/docs/playing_guide_test.exs
git --no-pager diff docs/PLAYING.md
```

If any support set now reports a max of 0, stop and report it: that means labour has made the set unsatisfiable at every residential count, which is a balance problem, not a generator problem.

- [ ] **Step 7: Mutation-verify the two new tests**

Change `labour: 12.0` to `labour: 0.0` in the industrial consumption table. Confirm *both* new tests fail and that the failure names them. Restore, and confirm green.

- [ ] **Step 8: Prose in PLAYING.md**

`PLAYING.md` has generated blocks and hand-written prose between them. The prose around the capacities table explains the ratio in terms of power and water only. Add a sentence naming the new constraint, in the existing voice. Do not touch anything between generated-block markers.

- [ ] **Step 9: Full gate and commit**

```bash
mix check
git add -A && git commit
```

Commit message: what labour is, why baseline zero is load-bearing, and why the guide's search algorithm changed.

---

### Task 2: The treasury field and old-snapshot hydration

**Files:**
- Modify: `lib/armchair_metropolist/domain/entities/city_map.ex` — `defstruct`, `@type t`
- Modify: `lib/armchair_metropolist/infrastructure/simulation/city_engine.ex` — `load_city_map/0`
- Test: `test/armchair_metropolist/infrastructure/simulation/city_engine_test.exs`

**Interfaces:**
- Produces: `%CityMap{money: 500.0}` by default; `CityMap.new/2` returns a map carrying it. Task 3 reads and writes this field.

- [ ] **Step 1: Write the failing test** — a city stored before the field existed must still load:

```elixir
# Every stored city predates `money`. A term encoded without it decodes under
# :safe as a struct carrying only the old keys, and reading .money then raises
# KeyError *after* a successful load — crash-looping this supervised process
# rather than falling back to a new city. Nothing else in the suite constructs a
# CityMap from a term missing a field, so without this the regression is silent.
test "a snapshot stored before the money field loads with the default balance" do
  legacy = %{
    __struct__: ArmchairMetropolist.Domain.Entities.CityMap,
    width: 40,
    height: 30,
    tick: 7,
    nodes: %{"0:0" => Node.new(0, 0, :park)}
  }

  round_tripped = :erlang.binary_to_term(:erlang.term_to_binary(legacy), [:safe])
  loaded = CityEngine.normalize_city_map(round_tripped)

  assert loaded.money == 500.0
  assert loaded.tick == 7
  assert map_size(loaded.nodes) == 1
end
```

- [ ] **Step 2: Run it and watch it fail**

Run: `mix test test/armchair_metropolist/infrastructure/simulation/city_engine_test.exs -k "money field"`
Expected: FAIL — `normalize_city_map/1` is undefined.

- [ ] **Step 3: Add the field**

In `city_map.ex`, `defstruct width: 40, height: 30, tick: 0, nodes: %{}, money: 500.0`, add `money: float()` to `@type t`, and have `new/2` set it explicitly to `500.0` alongside the other fields, matching the existing style. Extend the `defstruct` warning comment: it currently warns about atom-valued fields and `SnapshotVocabulary`; add that a field added here will be **absent from every already-stored city**, and must be defaulted on load.

- [ ] **Step 4: Normalise on load**

In `city_engine.ex`, make `normalize_city_map/1` public (the test calls it directly; `@doc false` marks it as not part of the API) and apply it in `load_city_map/0` on the `{:ok, {_stored_tick, city_map}}` branch, replacing the bare `city_map` with `normalize_city_map(city_map)`.

Write exactly one clause. A `%CityMap{} = city_map` fast-path clause would be worse than useless: struct pattern-matching only tests `__struct__`, which a legacy term also carries, so that clause would match the very terms needing repair and return them unfixed.

```elixir
  @doc false
  # A stored city is whatever shape CityMap had when it was written. Decoding gives
  # back a struct with only those keys, so a field added later is *missing*, not
  # defaulted, and the first read raises KeyError long after the load succeeded.
  # Merging onto a fresh struct fills new fields and leaves stored ones alone.
  def normalize_city_map(stored) when is_map(stored) do
    Map.merge(%CityMap{}, Map.delete(stored, :__struct__))
  end
```

- [ ] **Step 5: Run the test, then the suite**

Run: `mix test test/armchair_metropolist/infrastructure/simulation/city_engine_test.exs` then `mix test`
Expected: PASS, no other failures. The guide is unaffected — no table changed.

- [ ] **Step 6: Mutation-verify**

Replace the merge body with `stored` and confirm the new test fails with a `KeyError` on `:money`. Restore.

- [ ] **Step 7: Commit**

---

### Task 3: Carry-over in the calculator

The mechanism, with no money in the tables yet — so this task changes behaviour for zero resources and must leave every existing number untouched.

**Files:**
- Modify: `lib/armchair_metropolist/domain/services/simulation_calculator.ex`
- Modify: `lib/armchair_metropolist/domain/entities/simulation_metrics.ex` — `@type resource_stats`
- Test: `test/armchair_metropolist/domain/services/simulation_calculator_test.exs`

**Interfaces:**
- Consumes: `CityMap.money` from Task 2.
- Produces: `resource_stats/1` entries gain `carried: float()`. `advance_tick/1` returns a city map whose `money` is `max(0.0, supplied + carried - demanded)`. Task 4 supplies the tables that make this non-trivial; Task 5 reads `carried` and the balance.

- [ ] **Step 1: Write the failing test**

```elixir
test "every flow resource carries nothing" do
  stats = Calc.resource_stats(sustainable_city())
  # Asserted explicitly so that folding the balance back into `supplied` later
  # cannot pass silently.
  for resource <- [:power, :water, :waste, :traffic, :labour] do
    assert Map.fetch!(stats, resource).carried == 0.0
  end
end

test "an untouched city keeps its balance across a tick" do
  {advanced, _delta} = Calc.advance_tick(sustainable_city())
  # Nothing produces or consumes money yet, so the grant is untouched.
  assert advanced.money == 500.0
end
```

- [ ] **Step 2: Run and watch fail** — `KeyError` on `:carried`.

- [ ] **Step 3: Implement**

Add the carry-over list and thread it through. `resource_stats/1` already receives the city map:

```elixir
  # The resources whose unspent supply survives the tick boundary. Every other
  # resource discards its surplus; money is a treasury. Named as a list rather
  # than tested against the atom :money at each site.
  @carryover [:money]

  def resource_stats(city_map) do
    nodes = CityMap.nodes(city_map)
    supply = total_supply(nodes)
    demand = total_demand(nodes)

    Map.new(@resources, fn resource ->
      supplied = Map.fetch!(supply, resource)
      carried = carried(city_map, resource)
      demanded = Map.fetch!(demand, resource)
      available = supplied + carried

      stats = %{
        supplied: supplied,
        carried: carried,
        demanded: demanded,
        deficit: max(0.0, demanded - available),
        satisfaction: satisfaction(available, demanded)
      }

      {resource, stats}
    end)
  end

  # Derived from @carryover rather than matching on :money directly, so the list
  # is the single place a reader looks to learn which resources are treasuries.
  defp carried(city_map, resource) when resource in @carryover, do: city_map.money
  defp carried(_city_map, _resource), do: 0.0
```

In `advance_tick/1`, carry the new balance into the returned map:

```elixir
    money = new_balance(Map.fetch!(stats, :money))

    {%{city_map | nodes: nodes, tick: city_map.tick + 1, money: money}, delta}
```

```elixir
  # Floors at zero: debt is not modelled. An upkeep that cannot be paid shows up
  # as satisfaction below 1.0, which the existing decay path already handles.
  defp new_balance(%{supplied: supplied, carried: carried, demanded: demanded}) do
    max(0.0, supplied + carried - demanded)
  end
```

Update `@type resource_stats` in `simulation_metrics.ex` to include `carried: float()`, and document the invariant in the typedoc: satisfaction is computed over `supplied + carried`, so `supplied` alone is the flow.

Update the calculator's moduledoc, which currently numbers the tick's steps: step 1 must mention the carried balance, and a new step records that money's surplus persists.

- [ ] **Step 4: Run the suite**

Run: `mix test`
Expected: all green. No existing number moves — `carried` is `0.0` everywhere and money has no producers or consumers yet.

- [ ] **Step 5: Mutation-verify** — change `max(0.0, ...)` to `min(0.0, ...)` in `new_balance/1` and confirm the balance test fails; change `carried` to `1.0` for a flow resource and confirm the first test fails. Restore both.

- [ ] **Step 6: Commit**

---

### Task 4: The money tables and the guide's support sets

**Files:**
- Modify: `lib/armchair_metropolist/domain/entities/node.ex`
- Modify: `lib/armchair_metropolist/domain/services/simulation_calculator.ex` — `@baseline_capacity`
- Modify: `test/support/playing_guide.ex` — `@resources`, `@support_sets`, `city_with/1`, `capacities_block/0`
- Modify: `test/armchair_metropolist/domain/entities/node_test.exs`, `test/armchair_metropolist/domain/services/simulation_calculator_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
test "an unpayable upkeep starves the consumer once the treasury is empty" do
  # One park: upkeep 3/tick, no income. Start it broke rather than simulating
  # 167 ticks of drain.
  map = %{map_with([Node.new(0, 0, :park)]) | money: 0.0}
  stats = Calc.resource_stats(map)

  assert stats.money.demanded == 3.0
  assert stats.money.carried == 0.0
  assert stats.money.satisfaction == 0.0

  {advanced, _delta} = Calc.advance_tick(map)
  assert advanced.money == 0.0
  assert CityMap.get_node(advanced, 0, 0).health < 100.0
end

test "surplus income accumulates in the treasury" do
  # One commercial (+30) and one park (-3), starting from a known balance.
  map = %{map_with([Node.new(0, 0, :commercial), Node.new(1, 0, :park)]) | money: 100.0}
  {advanced, _delta} = Calc.advance_tick(map)
  assert_in_delta advanced.money, 127.0, 0.001
end
```

- [ ] **Step 2: Run and watch fail.**

- [ ] **Step 3: Add the tables** — `@resources` gains `:money` **last**; `@type resource` gains `| :money`; `commercial` produces `money: 30.0`; `residential` produces `money: 1.0` alongside its labour; `water_plant`, `road_hub` and `park` gain `money:` consumption of `5.0`, `4.0` and `3.0`. `@baseline_capacity` gains `money: 0.0`, commented: no free income is what forces commercial to be built.

- [ ] **Step 4: Update the pinning tests** — the six-element resource list, the exact baseline map, and the production/consumption assertions for all five changed types.

- [ ] **Step 5: Run the suite and triage**

Run: `mix test`
Expected: the new tests pass. `playing_guide_test.exs` fails. Watch specifically for `sub_rounding_city`: its money upkeep is 14/tick (one water plant, three parks) against the 500 grant, so satisfaction stays 1.0 and its hand-computed arithmetic still holds. **If that test fails, stop and report** — it means money has become a node's worst satisfaction and the fixture's documented reasoning is void.

- [ ] **Step 6: Give the guide's support sets a commercial block**

Every documented support set is insolvent without one — upkeep 9, 14 and 23 per tick against measured maxima of 5, 9 and 15 residential, so the 500 grant empties inside the generator's 120-tick window and every row would regenerate as 0.

Widen `@support_sets` to five-tuples and thread `commercial` through `city_with/1`, `capacities_block/0` and `residential_range/5` (introduced in Task 1).

**The sets must be rebalanced, not merely extended.** Solved against the new tables at full
health, appending one commercial to the existing sets gives:

| set | viable residential |
|---|---|
| 1 power, 1 water, 1 industrial, 1 road, 1 commercial | **none** |
| 2 power, 2 water, 1 industrial, 1 road, 1 commercial | 5–7 |
| 3 power, 3 water, 2 industrial, 2 road, 2 commercial | 10–12 |

The first is contradictory: one industrial and one commercial demand 20 labour, needing r ≥ 5,
while power supply of 160 against a demand of `95 + 15r` caps r at 4. The smallest set that admits
any city is `{2, 1, 1, 1, 1}`, at exactly 5 residential. Use:

```elixir
  # Commercial is part of a viable support set now, not an optional extra: without it
  # a city's only income is 1 per residential, which cannot cover the water plants and
  # road hubs that residential itself requires.
  #
  # These are solved, not guessed. {1,1,1,1,1} has NO viable residential count —
  # industrial and commercial demand 20 labour (r >= 5) while power caps r at 4 — so
  # the smallest set carries a second power plant.
  @support_sets [{2, 1, 1, 1, 1}, {2, 2, 1, 1, 1}, {3, 3, 2, 2, 2}]
```

**Measure from an empty treasury.** `city_with/1` must set `money: 0.0` on the city it builds:

```elixir
    # Not the 500.0 grant. Over the 120-tick window a city whose income falls one
    # short of its upkeep drains the grant at 1/tick and survives all 120 ticks —
    # so the guide would certify a city that goes bankrupt on tick 501. Starting
    # broke measures the steady-state economy: income must cover upkeep every tick.
    %{city | money: 0.0}
```

Update the table header and row template to name the commercial count. The measured range now has
a meaningful *lower* bound too — too few residents cannot staff the industry — so add a "min
residential" column beside the max; it is the clearest way the table can teach the labour
constraint. Then regenerate and read the diff:

```bash
REGENERATE_PLAYING_GUIDE=1 mix test test/docs/playing_guide_test.exs
git --no-pager diff docs/PLAYING.md
```

**Do not accept a table of zeros.** If a set reports 0, the commercial count is too low to fund it — raise it and regenerate. Report the final numbers in the task report; they are the balance evidence for the whole feature, and the spec's §7 figures are arithmetic that has never been run.

- [ ] **Step 7: Rewrite the affected prose**

`PLAYING.md`'s hand-written sections state the equilibrium ratio and carry a recovery table, both computed against the old coupling. The line "Produce nothing at all: `commercial`, `residential`" is generated and will fix itself; the prose will not. Rewrite the ratio discussion around the regenerated numbers, and re-derive or remove the recovery table — do not leave numbers that the simulation no longer produces.

- [ ] **Step 8: Mutation-verify both new tests, then `mix check` and commit.**

---

### Task 5: Surfacing the treasury

**Files:**
- Modify: `lib/armchair_metropolist/domain/entities/simulation_metrics.ex` — `money` field
- Modify: `lib/armchair_metropolist_web/live/simulator_live.ex` — `metrics/1`
- Test: `test/armchair_metropolist/domain/entities/simulation_metrics_test.exs`, `test/armchair_metropolist_web/live/simulator_live_test.exs`

**Interfaces:**
- Consumes: `CityMap.money` (Task 2), `resource_stats` `carried` (Task 3).
- Produces: `%SimulationMetrics{money: float()}`, and a `#metrics-treasury` element in the rendered page.

- [ ] **Step 1: Write the failing tests**

```elixir
# simulation_metrics_test.exs — the LiveView receives metrics and never the city
# map, so without this field the balance cannot reach the page at all.
test "carries the city's treasury balance" do
  city_map = %{CityMap.new(40, 30) | money: 275.0}
  metrics = SimulationMetrics.build(city_map, %{})
  assert metrics.money == 275.0
end
```

```elixir
# simulator_live_test.exs
test "the metrics panel shows the treasury", %{conn: conn} do
  {:ok, view, _html} = live(conn, ~p"/")
  assert has_element?(view, "#metrics-treasury")
  assert view |> element("#metrics-treasury") |> render() =~ "500"
end
```

- [ ] **Step 2: Run and watch both fail.**

- [ ] **Step 3: Implement** — add `money: 0.0` to the `SimulationMetrics` defstruct and `money: float()` to `@type t`, populate it in `build/2` from `city_map.money`, and add a line to `metrics/1` beside the existing ones:

```heex
<p id="metrics-treasury">Treasury: {round(@metrics.money)}</p>
```

`round/1` matches every other figure on the panel; the balance is a running total and a fractional part is noise.

- [ ] **Step 4: Run the suite. Step 5: Mutation-verify** — set `money: 0.0` in `build/2` regardless of the city map, confirm both tests fail. Restore. **Step 6: Commit.**

---

### Task 6: Re-measure the wrap thresholds

Four resource columns became six. `render/1` carries `max-[1900px]` and `max-[1287px]`, chosen as the midpoints of measured windows `[1813, 1988]` and `[1215, 1358]`. Both windows have moved.

**Files:**
- Modify: `lib/armchair_metropolist_web/live/simulator_live.ex` — the two constants and the comment recording the measurement
- Modify: `test/armchair_metropolist_web/live/simulator_live_test.exs` — the threshold test asserting the two class names

- [ ] **Step 1: Start the dev server** with `preview_start` (never `mix phx.server` via Bash) and place a few blocks of several types so the legend renders real totals.

- [ ] **Step 2: Measure both windows, expanded and collapsed.** Clone the layout row into an off-screen host of settable width, binary-search the width at which the sidebar stops wrapping — once with the sidebar's children stacked (`W_col`) and once with them in a row (`W_row`) — and add the page chrome to convert a content width to a viewport width. **Validate the harness before trusting it**: check that it reproduces the live page's current wrapped/unwrapped state at the current viewport. Repeat with the legend collapsed.

- [ ] **Step 3: Take the midpoint of each window**, not an endpoint. An endpoint is where the layout changes, so a constant placed there falls out of the window on the next content change — which is exactly how the previous pair broke.

- [ ] **Step 4: Verify at the boundary pixels.** For each state, resize to `N - 1` and `N` and confirm that the sidebar and Metrics never agree on a side: beside-the-grid must pair with Metrics stacked, below-the-grid with Metrics alongside. Confirm no layout produces a horizontal scrollbar and that the table renders at its natural width. Tailwind compiles `max-[N]` to `@media (width < N)`, exclusive, so `N` is the first viewport that must *not* get the row layout — test `N` itself, not near it.

- [ ] **Step 5: Update the constants, the comment recording the measured windows, and the test** that pins both class names.

- [ ] **Step 6: Stop the preview server**, `mix check`, and commit with the measured windows in the message.

---

## Notes for the executor

- **The two new legend columns need no template change and no new test.** `legend/1` renders one column per `Node.resources()` entry, and `simulator_live_test.exs:454` already loops over that list asserting a cell per resource per type — so both columns are covered the moment the vocabulary grows. If that test fails in Task 1 or Task 4, the cause is a missing table entry, not the template.
- `tightest_resource/1` and the engine's deficit notification (`city_engine.ex:283`) both iterate all resources and pick up labour and money automatically. For money the notification correctly stays quiet until the balance is exhausted, because satisfaction counts the carried balance.

- Tasks 1 and 4 both regenerate `PLAYING.md`. Read the diff each time rather than trusting the command: the generator now measures a simulation whose balance changes over the run, and a silently-zeroed table looks like a successful regeneration.
- The spec's §7 balance figures are arithmetic against the guide's old numbers and have never been executed. Task 4 Step 6 is where they meet reality. If the measured maxima disagree with the spec, the measurement wins — report it rather than tuning the guide to match the spec.
- If any task leaves `mix check` red, stop and report. Do not carry a failing gate into the next task.
