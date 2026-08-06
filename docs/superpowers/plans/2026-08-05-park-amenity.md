# Park Amenity and Staffing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `park` worth building by having parks multiply the labour their housing supplies, and staff every block except housing so labour becomes the cost of building anything that is not a home.

**Architecture:** Five table entries (pure data — four types gain a labour draw, `residential`'s labour output rises 4 → 5), plus one new step in `SimulationCalculator.total_supply/1` that scales the labour figure by an amenity multiplier derived from effective parks per effective housing block. The multiplier reaches the UI on the `SimulationMetrics` struct, because the boundary graph bars the web layer from `Domain.Services`. Nothing persisted changes shape, so there is no snapshot migration.

**Tech Stack:** Elixir 1.20.2 / OTP 29, Phoenix LiveView, ExUnit + StreamData, `boundary` compiler, `mix check`.

**Spec:** `docs/superpowers/specs/2026-08-05-park-amenity-design.md`

## Global Constraints

- **The amenity rule is** `1 + k × min(parks / housing, cap)` applied to total labour supply, with `k = 1.0` (`@amenity_per_housing`) and `cap = 1.0` (`@max_amenity_ratio`). Max multiplier ×2.0.
- **`housing` and `parks` are health-weighted**, not counted: `Σ health / 100` over nodes of that type.
- **`housing == 0.0` returns `1.0` via an explicit guard.** Erlang does not follow IEEE 754 — `0.0 / 0.0` raises `ArithmeticError`. This is not optional.
- **Staffing values:** `transit_hub` `2.0`, `power_plant` `1.0`, `water_plant` `1.0`, `park` `1.0`. All go in `@consumption_table`, never in `@production_table`, so the demand is never health-scaled.
- **`residential` draws no labour and produces `5.0` of it.** It is the sole exemption from the staffing rule and the sole source of labour.
- **`L × k` must stay a whole number**, where `L` is `residential`'s labour output and `k` is `@amenity_per_housing`. At `L = 5, k = 1.0` the gross bonus per park is 5. The legend's `signed/1` rounds, so a fractional product would render a figure the engine does not supply.
- **Every figure in a domain table stays a whole number**, for the same reason.
- **Do not edit `PlayingGuide`'s `@support_sets`.** Every documented support set stays viable under these values; a set reading `none` means something else is wrong.
- **Test discipline (non-negotiable, from `docs/superpowers/2026-07-30-follow-ups.md`):** every new test must be seen to fail before it is trusted — break the code, confirm red, restore. Never write a `refute` without asserting the positive case first.
- **`mix check` must exit 0** before the final commit. It runs version checks, `format --check-formatted`, `compile --force --warnings-as-errors`, `sobelow`, `deps.audit`, and `test --cover` with a 90% coverage threshold.
- **Do not restore a file with `git checkout`.** When you mutate code to verify a test fails, restore it with an inverse edit or from a copy you made first. `git checkout` here has destroyed uncommitted work before.
- **Baseline before you start:** `mix test` reports `254 passed (5 properties, 249 tests)`. The `[reaper] sweep failed ... ArithmeticError` warnings in the output are pre-existing deliberate error-injection noise, not a problem you introduced.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `lib/armchair_metropolist/domain/entities/node.ex` | Modify: four `@consumption_table` entries + `residential`'s labour output | 1 |
| `test/armchair_metropolist/domain/entities/node_test.exs` | Modify: the literal table assertions; add a staffing-boundary test | 1 |
| `test/armchair_metropolist/domain/services/simulation_calculator_test.exs` | Modify: **four** hand-derived fixtures re-solved; add amenity + staffing tests | 1, 2, 3 |
| `test/support/playing_guide.ex` | Modify: add measured amenity constants (**not** `@support_sets`) | 5 |
| `docs/PLAYING.md` | Regenerate blocks; rewrite three prose passages | 1, 5 |
| `test/docs/playing_guide_test.exs` | Modify: add a support-set viability test | 1 |
| `lib/armchair_metropolist/domain/services/simulation_calculator.ex` | Modify: amenity attributes, `total_supply/1`, `metrics/1` | 2, 3 |
| `lib/armchair_metropolist/domain/entities/simulation_metrics.ex` | Modify: two fields, `build/3` | 3 |
| `test/armchair_metropolist/domain/entities/simulation_metrics_test.exs` | Modify: add default-field assertions | 3 |
| `lib/armchair_metropolist_web/live/simulator_live.ex` | Modify: `resource_cell`, `marginal_cell`, `metrics` component | 4 |
| `test/armchair_metropolist_web/live/simulator_live_test.exs` | Modify: add presentation tests | 4 |

---

## Task 1: Staff every type except housing, and raise housing's output

Five table entries: four consumption tables gain labour, and `residential`'s production rises from 4.0
to 5.0 to absorb them. The fallout is much larger than the change — **seven** tests fail, and four of
them are hand-derived fixtures whose exact arithmetic has to be re-solved. Every value below was
verified by applying this change, running the suite green, and then restoring the tree.

**Files:**
- Modify: `lib/armchair_metropolist/domain/entities/node.ex:43-62`
- Modify: `test/armchair_metropolist/domain/entities/node_test.exs`
- Modify: `test/armchair_metropolist/domain/services/simulation_calculator_test.exs`
- Modify: `docs/PLAYING.md` (regenerated)
- **Not** modified: `test/support/playing_guide.ex`. `@support_sets` needs no edit — every set stays
  viable. Do not change it.

**Interfaces:**
- Consumes: nothing.
- Produces: `Node.production(:residential)[:labour] == 5.0`; `Node.consumption/1` gains `labour` for
  `power_plant` (1.0), `water_plant` (1.0), `transit_hub` (2.0) and `park` (1.0). Task 2's algebra
  depends on `L = 5.0`; Task 4 reads `Map.get(Node.consumption(:park), :labour, 0.0)`.

- [ ] **Step 1: Write the failing tests**

Add to `test/armchair_metropolist/domain/entities/node_test.exs`, in the same describe block as the
existing table test:

```elixir
    test "everything but housing is staffed, and housing supplies the staff" do
      # Positive cases first: without these, the refutation below is satisfied by a
      # consumption table that mentions labour nowhere at all.
      assert Node.consumption(:industrial)[:labour] == 12.0
      assert Node.consumption(:commercial)[:labour] == 8.0
      assert Node.consumption(:transit_hub)[:labour] == 2.0
      assert Node.consumption(:power_plant)[:labour] == 1.0
      assert Node.consumption(:water_plant)[:labour] == 1.0
      assert Node.consumption(:park)[:labour] == 1.0

      # The one exemption, and the whole reason the rule is statable.
      refute Map.has_key?(Node.consumption(:residential), :labour),
             "residential is the source of labour, not a consumer — see the park amenity spec, §3"

      # Pinned because `L` is half of the `L x k` integrality constraint the legend
      # depends on (spec §2): at L = 5 and k = 1.0 the gross bonus per park is 5.
      assert Node.production(:residential)[:labour] == 5.0
    end
```

Add to `test/armchair_metropolist/domain/services/simulation_calculator_test.exs`, in the
`resource_stats/1` describe block:

```elixir
    test "staffing demand is not scaled by health" do
      healthy = map_with([Node.new(0, 0, :transit_hub)])
      dead = map_with([%Node{Node.new(0, 0, :transit_hub) | health: 0.0, status: :offline}])

      # Asserted in both states deliberately. Only the dead case can fail if staffing
      # were health-scaled, and only the healthy case proves the figure is 2.0 at all.
      assert Calc.resource_stats(healthy).labour.demanded == 2.0
      assert Calc.resource_stats(dead).labour.demanded == 2.0
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
mix test test/armchair_metropolist/domain/entities/node_test.exs test/armchair_metropolist/domain/services/simulation_calculator_test.exs
```

Expected: both new tests FAIL — `nil == 2.0` in the first, `0.0 == 2.0` in the second.

- [ ] **Step 3: Apply the table changes**

In `lib/armchair_metropolist/domain/entities/node.ex`, one production line:

```elixir
    residential: %{labour: 5.0, money: 1.0},
```

and four consumption lines:

```elixir
    power_plant: %{water: 20.0, waste: 12.0, traffic: 3.0, labour: 1.0},
    water_plant: %{power: 25.0, waste: 6.0, traffic: 2.0, money: 5.0, labour: 1.0},
    transit_hub: %{power: 8.0, waste: 2.0, money: 4.0, labour: 2.0},
    park: %{water: 18.0, traffic: 2.0, money: 3.0, labour: 1.0}
```

- [ ] **Step 4: Run the full suite and confirm exactly seven failures**

```bash
mix test
```

Expected: `Result: 249/256 passed` — the 254 baseline plus Step 1's two tests, which now pass. Failing on:

1. `node_test.exs` "match the specified supply/demand table" — literal table assertions.
2. `simulation_calculator_test.exs` "enough housing staffs the industry and stops the decay".
3. `simulation_calculator_test.exs` "worst ratio considers only resources the node consumes".
4. `simulation_calculator_test.exs` "excludes a node whose health moves within the same rounded value".
5. `simulation_calculator_test.exs` "computes resource stats once from the pre-tick map, whatever the node order".
6. `simulation_calculator_test.exs` "includes a node whose status flips at unchanged rounded health".
7. `playing_guide_test.exs` — the guide is out of date.

If you get a different count, stop and investigate rather than pressing on. Steps 5–10 fix these
seven and nothing else.

- [ ] **Step 5: Update the literal table assertions**

In `test/armchair_metropolist/domain/entities/node_test.exs`:

```elixir
      assert Node.consumption(:power_plant) == %{water: 20.0, waste: 12.0, traffic: 3.0, labour: 1.0}
```

```elixir
      assert Node.consumption(:water_plant) == %{
               power: 25.0,
               waste: 6.0,
               traffic: 2.0,
               money: 5.0,
               labour: 1.0
             }
```

```elixir
      assert Node.consumption(:transit_hub) == %{power: 8.0, waste: 2.0, money: 4.0, labour: 2.0}
```

```elixir
      assert Node.production(:residential) == %{labour: 5.0, money: 1.0}
```

```elixir
      assert Node.consumption(:park) == %{water: 18.0, traffic: 2.0, money: 3.0, labour: 1.0}
```

- [ ] **Step 6: Fix "enough housing staffs the industry"**

Labour demand is now 14.0 — the industrial block's 12 plus 1 each for the power and water plants the
fixture already contains. Supply is 3 residential x 5.0 = 15.0. Change two lines:

```elixir
      assert stats.labour.demanded == 14.0
      assert stats.labour.supplied == 15.0
```

`satisfaction == 1.0` still holds (15 >= 14) and needs no change. Update the comment's opening line,
which is now wrong in both figures:

```elixir
      # 3 residential supply 15 labour against a demand of 14: the industrial block's
      # 12, plus 1 each for the power and water plants below. The margin is deliberate
      # slack — there is no residential count that makes this exact, because housing
      # comes in units of 5.
```

- [ ] **Step 7: Fix "worst ratio considers only resources the node consumes"**

This starves power and asserts a park is untouched, because a park consumes no power. It used ten
`commercial` blocks as power hogs — and `commercial` draws 8 labour each, so with no housing the
city's labour satisfaction is 0.0, the park's worst ratio is 0.0, and it decays for a reason the test
is not about. Measured before the fix: the park lands on 74.0 against an asserted `>= 80.0`.

`residential` is the right hog — it draws power 15, draws no labour, and *supplies* the labour the
park now needs:

```elixir
      power_hogs = for x <- 1..10, do: Node.new(x, 1, :residential)
```

Extend the comment so the next reader knows the type is load-bearing:

```elixir
      # A park consumes water and traffic but no power, so a total blackout
      # must leave it untouched.
      #
      # The hogs are `residential`, not `commercial`: a park draws labour now, and
      # `commercial` draws 8 each, so a commercial-only city has labour satisfaction 0.0
      # and the park would decay on labour rather than being untouched — passing the
      # blackout premise while testing nothing. `residential` draws power and supplies
      # the labour instead.
```

- [ ] **Step 8: Re-derive the two shared-shape fixtures**

Failures 4 and 5 use the same five-node shape — a water plant, a power plant and three parks. Staffing
breaks it at the root: the power plant now draws labour, nothing houses anyone, so labour satisfaction
is 0.0 and the plant takes the full 6.0 decay to 84.0 instead of the 0.30 that put it on 89.7.

Adding one residential block supplies 5 labour against a demand of 5 (power 1 + water 1 + parks 3).
But it also adds water 12, taking water demand from 74.0 to **86.0** — so the water plant's health must
be re-solved to restore satisfaction 0.95: `supply = 0.95 x 86.0 = 81.7`, and `supply = 40 + 100h`
gives `h = 41.7`.

Verified: the power plant lands on 89.7 exactly as before, and the water plant regenerates 41.7 ->
42.7, still crossing a rounding boundary (42 -> 43) so the delta is not trivially empty.

In `sub_rounding_city/0`:

```elixir
  defp sub_rounding_city do
    map_with([
      %Node{Node.new(0, 0, :water_plant) | health: 41.7, status: :degraded},
      %Node{Node.new(1, 0, :power_plant) | health: 90.0, status: :online},
      Node.new(0, 3, :park),
      Node.new(1, 3, :park),
      Node.new(2, 3, :park),
      Node.new(5, 5, :residential)
    ])
  end
```

Replace the stale arithmetic in its comment — the old block derives water demand as 74.0 and describes
a five-node city:

```elixir
  # A city where water is only *slightly* short, so the resulting decay is
  # fractional and stays inside a single rounded health value.
  #
  #   power    supply 40 + 120*0.900 = 148.0   demand 25 + 15 = 40.0        -> 1.0
  #   water    supply 40 + 100*0.417 =  81.7   demand 20 + 3*18 + 12 = 86.0 -> 0.95
  #   waste    supply 40 + 3*8       =  64.0   demand 12 + 6 + 10 = 28.0    -> 1.0
  #   traffic  supply 40             =  40.0   demand 3 + 2 + 6 + 6 = 17.0  -> 1.0
  #   labour   supply 1*5.0          =   5.0   demand 1 + 1 + 3*1 = 5.0     -> 1.0
  #
  # The residential block is not decoration: since everything but housing is staffed
  # (2026-08-05) this city draws 5 labour, and without a house to supply it labour
  # satisfaction is 0.0 and *both* plants take the full 6.0 decay — which destroys the
  # sub-rounding movement this fixture exists to produce. Its water draw of 12 is why the
  # water plant sits at 41.7 rather than 30.3: water demand is 86.0 now, and 0.95 of that
  # is 81.7 = 40 baseline + 41.7 health-scaled.
  #
  # Money is absent from the table because it is not meant to bind: demand is the water
  # plant's 5 plus 3 per park = 14, against a supply of 1 from the residential block,
  # covered as `carried` by `CityMap.new/2`'s default 500.0 grant.
  #
  # The power plant consumes water/waste/traffic/labour, so its worst ratio is exactly
  # 0.95 (86.0 * 0.95 == 81.7) and its delta is -(1 - 0.95) * 6.0 = -0.30, taking it from
  # 90.0 to 89.7. round(90.0) == round(89.7) == 90 and the status stays :online, so its
  # display signature does not move.
  #
  # The water plant sits at "0:0" and the power plant at "1:0" deliberately. Maps iterate
  # in key order, so the water plant -- which regenerates from 41.7 to 42.7 this tick --
  # is processed first. An implementation that recomputed resource stats per node would
  # then hand the power plant a water supply of 82.7 (satisfaction 0.9616, health 89.77)
  # instead of 81.7.
```

Failure 5 keeps its own inline copy of the same node list. Apply the identical change there, and
update its expected water-plant health:

```elixir
      nodes = [
        %Node{Node.new(0, 0, :water_plant) | health: 41.7, status: :degraded},
        %Node{Node.new(1, 0, :power_plant) | health: 90.0, status: :online},
        Node.new(0, 3, :park),
        Node.new(1, 3, :park),
        Node.new(2, 3, :park),
        Node.new(5, 5, :residential)
      ]
```

```elixir
      assert_in_delta CityMap.get_node(forward, 0, 0).health, 42.7, 0.001
```

Its comment's per-node-recompute figures also move — replace `71.3 (satisfaction 0.9635, delta -0.219,
health 89.78)` with `82.7 (satisfaction 0.9616, delta -0.230, health 89.77)` and `70.3 (satisfaction
0.95, delta -0.30, health 89.7)` with `81.7 (satisfaction 0.95, delta -0.30, health 89.7)`.

- [ ] **Step 9: Re-derive the status-flip fixture**

Failure 6 needs the same treatment with a different target. It wants water satisfaction 0.86667 so the
power plant's delta is -0.8, taking 60.4 to 59.6 — round 60 on both sides, status flipping to
`:degraded`. With one residential added, water demand is again 86.0, so `supply = 0.86667 x 86.0 =
74.533` and the water plant's health is `(74.533 - 40) = 34.5333`.

```elixir
      map =
        map_with([
          %Node{Node.new(1, 0, :power_plant) | health: 60.4, status: :online},
          %Node{Node.new(0, 0, :water_plant) | health: 34.5333, status: :degraded},
          Node.new(0, 3, :park),
          Node.new(1, 3, :park),
          Node.new(2, 3, :park),
          Node.new(5, 5, :residential)
        ])
```

And its comment's arithmetic:

```elixir
      # Fixture arithmetic. Water demand is the plant's 20, 3 parks at 18, and the
      # residential block's 12 = 86; supply is the 40 baseline plus the water plant's
      # health-scaled output. A water plant at 34.5333 gives 74.5333/86 = 0.86667
      # satisfaction, so the power plant's delta is -(1 - 0.86667) * 6.0 = -0.8, taking
      # 60.4 to 59.6. Waste, traffic and labour stay fully satisfied, so water is
      # genuinely its worst — the residential block is what keeps labour at 1.0, since
      # every type here but housing draws staff.
```

- [ ] **Step 10: Regenerate the guide**

```bash
REGENERATE_PLAYING_GUIDE=1 mix test test/docs/playing_guide_test.exs
git --no-pager diff --no-ext-diff docs/PLAYING.md
```

Use `--no-ext-diff`: this repo configures difftastic and plain `git diff` is not a unified diff.

Expected: exactly these changes, and **no row lost from the capacities block**:

```
-| 2 power, 2 water, 1 industrial, 1 transit, 1 commercial | 7 | 5 | **7** | 14 | 0.5 |
+| 2 power, 2 water, 1 industrial, 1 transit, 1 commercial | 7 | 6 | **7** | 14 | 0.5 |
-| `residential` | labour 4, money 1 |
+| `residential` | labour 5, money 1 |
-| `park` | — | 18 | — | 2 | — | 3 |
-| `power_plant` | — | 20 | 12 | 3 | — | — |
+| `park` | — | 18 | — | 2 | 1 | 3 |
+| `power_plant` | — | 20 | 12 | 3 | 1 | — |
-| `transit_hub` | 8 | — | 2 | — | — | 4 |
-| `water_plant` | 25 | — | 6 | 2 | — | 5 |
+| `transit_hub` | 8 | — | 2 | — | 2 | 4 |
+| `water_plant` | 25 | — | 6 | 2 | 1 | 5 |
```

If a capacities row reads `none none none none`, a support set has become unviable and something above
is wrong — do not commit it and do not "fix" it by editing `@support_sets`.

- [ ] **Step 11: Add a test that no support set publishes "none"**

A `none` row is valid generator output, so nothing else fails if one is published. In
`test/docs/playing_guide_test.exs`:

```elixir
  test "every documented support set is viable" do
    capacities = PlayingGuide.blocks()["capacities"]

    # Positive case first: a `refute` against "none" is trivially satisfied by an empty
    # block, so prove the block has real rows before refuting the bad one.
    assert capacities =~ "residential per tile"
    assert capacities =~ ~r/\| \*\*\d+\*\* \|/, "expected at least one measured row"

    refute capacities =~ "none",
           "a support set has no viable residential count — its labour demand probably " <>
             "outgrew what its water plants can house"
  end
```

- [ ] **Step 12: Run the full suite**

```bash
mix test
```

Expected: `Result: 257 passed` — the 254 baseline, plus Step 1's two tests, plus Step 11's viability
test. (The trial run that verified every value in this task reached 254 with the fixtures fixed and
none of the three new tests written, so 257 is that figure plus three.)

- [ ] **Step 13: Mutation-verify**

Break each, confirm the named test goes red, restore by inverse edit (**never** `git checkout` — it has
destroyed uncommitted work on this repo before):

1. `residential` production back to `labour: 4.0` → the node_test staffing test fails, and so does
   "enough housing staffs the industry" (supply 12 not 15). Two failures is correct.
2. Add `labour: 1.0` to `residential`'s *consumption* → the `refute` in the staffing test fails.
3. Remove `power_plant`'s `labour: 1.0` → the re-derived fixtures fail, because their labour demand
   drops to 4 and the arithmetic no longer matches.
4. Make `total_demand/1` health-scale consumption → "staffing demand is not scaled by health" fails on
   the dead case.

- [ ] **Step 14: Commit**

```bash
git add lib/armchair_metropolist/domain/entities/node.ex test/armchair_metropolist/domain/entities/node_test.exs test/armchair_metropolist/domain/services/simulation_calculator_test.exs test/docs/playing_guide_test.exs docs/PLAYING.md
git commit -m "feat(domain): staff every block except the homes the staff live in

power_plant and water_plant draw 1 labour, transit_hub 2, park 1, and residential
rises from 4 to 5 labour to absorb them. Staffing on the consumption side, so the
demand is never health-scaled: a dead node keeps drawing its staff.

residential at 5 is what makes this viable rather than destructive. At 4 the
largest documented support set becomes non-viable and the middle one collapses to
a single residential count; at 5 the smallest and largest return to exactly their
original bands and one cell in the whole capacities block moves. @support_sets
needs no edit.

Four hand-derived fixtures re-solved against the new water demand of 86.0: the
sub-rounding water plant moves 30.3 -> 41.7 and the status-flip one 24.1333 ->
34.5333, both keeping their power plants on the same health as before."
```
---

## Task 2: The amenity multiplier

**Files:**
- Modify: `lib/armchair_metropolist/domain/services/simulation_calculator.ex`
- Modify: `test/armchair_metropolist/domain/services/simulation_calculator_test.exs`

**Interfaces:**
- Consumes: Task 1's staffing (park's own labour draw is what makes `k = 1.0` necessary).
- Produces: private `labour_multiplier(nodes) :: float()` and `labour_supply(nodes) :: float()` inside `SimulationCalculator`. Task 3 calls both. Nothing new is exported — the multiplier reaches tests through `resource_stats/1` and `metrics/1`.

- [ ] **Step 1: Write the failing tests**

Add to `test/armchair_metropolist/domain/services/simulation_calculator_test.exs` as a new describe block. The two helpers are local to it:

```elixir
  describe "park amenity" do
    defp labour_supplied(city) do
      city |> Calc.resource_stats() |> Map.fetch!(:labour) |> Map.fetch!(:supplied)
    end

    # `housing` residential blocks and `parks` parks, all at full health unless
    # overridden. Coordinates are irrelevant to the simulation and only need to be
    # distinct, so the two types sit on separate rows.
    defp housing_and_parks(housing, parks, opts \\ []) do
      housing_health = Keyword.get(opts, :housing_health, 100.0)
      park_health = Keyword.get(opts, :park_health, 100.0)

      residential =
        for i <- 1..housing//1 do
          %Node{
            Node.new(i, 0, :residential)
            | health: housing_health,
              status: Node.status_for(housing_health)
          }
        end

      park_nodes =
        for i <- 1..parks//1 do
          %Node{
            Node.new(i, 1, :park)
            | health: park_health,
              status: Node.status_for(park_health)
          }
        end

      map_with(residential ++ park_nodes)
    end

    test "no parks leaves labour supply unmultiplied" do
      assert labour_supplied(housing_and_parks(6, 0)) == 30.0
    end

    test "one park per housing block is the maximum, x2.0" do
      assert labour_supplied(housing_and_parks(6, 6)) == 60.0
    end

    test "past parity the multiplier is capped" do
      # Kills a missing `min/2`: uncapped this would be 6 residential x 5 x (1 + 20/6).
      assert labour_supplied(housing_and_parks(6, 20)) == 60.0
    end

    test "below the cap each park adds a constant L*k labour, whatever the city size" do
      # The identity that pins L, k, the legend's figure and the balance work together.
      # Asserted over several shapes rather than one, because a single pair is also
      # satisfied by formulas that are not this one. Expect 45.0, 80.0, 75.0, 50.0.
      for {housing, parks} <- [{6, 3}, {12, 4}, {10, 5}, {8, 2}] do
        assert labour_supplied(housing_and_parks(housing, parks)) ==
                 5.0 * housing + 5.0 * parks,
               "expected LH + LkP for H=#{housing} P=#{parks}"
      end
    end

    test "no housing means no labour, whatever the park count, and does not raise" do
      # Two claims: the design property, and that the zero-housing branch is guarded.
      # Erlang raises ArithmeticError on 0.0/0.0, so an unguarded division fails here
      # rather than returning a wrong number.
      assert labour_supplied(housing_and_parks(0, 8)) == 0.0
    end

    test "the amenity is health-weighted on the park side" do
      assert labour_supplied(housing_and_parks(8, 4)) == 60.0
      # 4 parks at half health is 2.0 effective parks against 8 housing: ratio 0.25,
      # so 40.0 base x 1.25.
      assert labour_supplied(housing_and_parks(8, 4, park_health: 50.0)) == 50.0
    end

    test "the amenity is health-weighted on the housing side" do
      # 8 blocks at half health supply 20 labour and count as 4.0 effective housing,
      # so 4 parks is parity and the multiplier caps at x2.0.
      assert labour_supplied(housing_and_parks(8, 4, housing_health: 50.0)) == 40.0
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
mix test test/armchair_metropolist/domain/services/simulation_calculator_test.exs
```

Expected: every test in the new block FAILS except "no parks leaves labour supply unmultiplied" and "no housing means no labour" — those two already pass, because the current code is the identity case. That is correct and expected: they are regression guards, not drivers.

- [ ] **Step 3: Add the amenity attributes**

In `lib/armchair_metropolist/domain/services/simulation_calculator.ex`, below `@carryover`:

```elixir
  # The park amenity: parks per housing block multiply labour supply. Both values are
  # measured, not chosen — see docs/superpowers/specs/2026-08-05-park-amenity-design.md
  # §4.
  #
  # `k` below 1.0 makes the whole mechanic a no-op, because a park draws 1 labour of its
  # own and so nets `4k - 1`: at k = 0.5 the net is +1, and the optimal city is
  # identical to one with no amenity at all. The cap is the ratio past which more parks
  # add nothing; it is inert in small cities and binds gently in large ones.
  @amenity_per_housing 1.0
  @max_amenity_ratio 1.0
```

- [ ] **Step 4: Apply the multiplier in `total_supply/1`**

Replace `total_supply/1` and add the two helpers beside it:

```elixir
  # Baseline capacity plus health-scaled production from every node, with labour then
  # scaled by the park amenity.
  #
  # Applied here rather than in `resource_stats/1` so there is exactly one labour supply
  # figure: satisfaction, deficit, health decay, the deficit notification and the
  # Tightest line all read this and cannot disagree about it.
  defp total_supply(nodes) do
    supply =
      Enum.reduce(nodes, @baseline_capacity, fn node, acc ->
        Enum.reduce(Node.effective_production(node), acc, &add_resource/2)
      end)

    Map.update!(supply, :labour, &(&1 * labour_multiplier(nodes)))
  end

  # Effective parks per effective housing block, capped, scaled by
  # `@amenity_per_housing`. Health-weighted on both sides: a neglected park provides no
  # amenity, and a dying neighbourhood needs fewer parks to serve it. A count-based
  # ratio would let a dead park go on multiplying, making `park` the one type neglect
  # cannot punish.
  #
  # The `housing > 0.0` guard is load-bearing, not defensive. Erlang does not follow
  # IEEE 754 for float division, so `0.0 / 0.0` raises `ArithmeticError` rather than
  # yielding NaN — it is not enough that the result would be multiplied by a zero labour
  # supply, because the division happens first. An empty city and a city bulldozed to
  # nothing but parks both reach this on an ordinary tick.
  defp labour_multiplier(nodes) do
    housing = effective_count(nodes, :residential)

    if housing > 0.0 do
      parks = effective_count(nodes, :park)
      1.0 + @amenity_per_housing * min(parks / housing, @max_amenity_ratio)
    else
      1.0
    end
  end

  # Counted by health rather than by node: a park at 40% health is 0.4 of a park.
  defp effective_count(nodes, type) do
    Enum.reduce(nodes, 0.0, fn
      %{type: ^type, health: health}, acc -> acc + health / 100.0
      _node, acc -> acc
    end)
  end
```

- [ ] **Step 5: Record the rule in the moduledoc**

The moduledoc's numbered list is the authoritative description of a tick. Amend step 1 so supply is not described as purely additive. Replace:

```
    1. `supply(r)` is the baseline capacity plus every node's *health-scaled*
       production of `r`, plus whatever balance `r` carried over from the
       previous tick (every resource but money carries nothing).
```

with:

```
    1. `supply(r)` is the baseline capacity plus every node's *health-scaled*
       production of `r`, plus whatever balance `r` carried over from the
       previous tick (every resource but money carries nothing). Labour is then
       multiplied by the **park amenity** — `1 + k × min(parks/housing, cap)`,
       both sides health-weighted — so parks raise the workforce their housing
       supplies without producing labour themselves. With no housing the
       multiplier is 1.0 and labour supply is 0.0 regardless of parks.
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
mix test test/armchair_metropolist/domain/services/simulation_calculator_test.exs
```

Expected: PASS, all of them.

- [ ] **Step 7: Run the full suite**

```bash
mix test
```

Expected: 254+ passing, no failures. If `playing_guide_test` fails here, the amenity has leaked into a support set — it must not, because every support set has zero parks and the multiplier is therefore exactly 1.0. Investigate rather than regenerate.

- [ ] **Step 8: Mutation-verify**

Break each, confirm the named test goes red, restore by inverse edit:

1. Drop the `min/2`: `1.0 + @amenity_per_housing * (parks / housing)` → "past parity the multiplier is capped" fails.
2. Set `@amenity_per_housing 0.5` → "each park adds a constant L*k" and both parity tests fail.
3. Replace `effective_count/2`'s health weighting with a plain count (`acc + 1.0`) → both health-weighted tests fail.
4. Replace the `housing > 0.0` guard with `true` → "no housing means no labour" fails with `ArithmeticError`, confirming the guard is what prevents a crash.

- [ ] **Step 9: Commit**

```bash
git add lib/armchair_metropolist/domain/services/simulation_calculator.ex test/armchair_metropolist/domain/services/simulation_calculator_test.exs
git commit -m "feat(domain): parks multiply the labour their housing supplies

labour supply x (1 + 1.0 * min(parks/housing, 1.0)), health-weighted on both
sides. Algebraically LH + LkP below the cap, so a park is worth a constant +5
labour gross regardless of city size — but zero when there is no housing, which
is what an additive labour output could not express.

The housing > 0.0 guard is required: Erlang raises ArithmeticError on 0.0/0.0
rather than yielding NaN."
```

---

## Task 3: Carry the amenity figures to the UI

The web layer cannot compute this. `ArmchairMetropolistWeb`'s boundary `deps` names `ArmchairMetropolist.Domain`, which exports only `Entities.*` and `Ports.*` — `Domain.Services.SimulationCalculator` is unreachable from a LiveView. And `SimulationMetrics` cannot call the calculator either, because `Domain` has `deps: []`. So the figures must be computed in `SimulationCalculator.metrics/1` and passed *into* `SimulationMetrics.build/3`.

**Files:**
- Modify: `lib/armchair_metropolist/domain/entities/simulation_metrics.ex`
- Modify: `lib/armchair_metropolist/domain/services/simulation_calculator.ex:143-146`
- Modify: `test/armchair_metropolist/domain/entities/simulation_metrics_test.exs`
- Modify: `test/armchair_metropolist/domain/services/simulation_calculator_test.exs`

**Interfaces:**
- Consumes: `labour_multiplier/1` and `total_supply/1` from Task 2.
- Produces: `%SimulationMetrics{amenity: float(), amenity_marginal_labour: float()}`, and `SimulationMetrics.build(city_map, resources, amenity \\ @default_amenity)` where `amenity` is `%{amenity: float(), amenity_marginal_labour: float()}`. Task 4 reads both struct fields.

- [ ] **Step 1: Write the failing tests**

Add to the `park amenity` describe block in `test/armchair_metropolist/domain/services/simulation_calculator_test.exs`:

```elixir
    test "metrics carries the multiplier and the labour one more park would add" do
      # 4 housing, 2 parks: ratio 0.5, so multiplier 1.5 and one more park is worth L*k.
      metrics = Calc.metrics(housing_and_parks(4, 2))

      assert metrics.amenity == 1.5
      assert metrics.amenity_marginal_labour == 5.0
    end

    test "the marginal figure is zero once parks have reached housing" do
      assert Calc.metrics(housing_and_parks(4, 4)).amenity_marginal_labour == 0.0
    end

    test "the marginal figure is the true difference where a park crosses the cap" do
      # Three healthy parks plus a half-dead one is 3.5 effective against 4 housing,
      # so ratio 0.875. One more park would reach 1.125 — above the cap — so the gain
      # is only the 0.125 of ratio that fits underneath it, not the full L*k of 5.0.
      #
      # This is the case the "L*k, or zero when saturated" shortcut gets wrong, and so
      # the case that justifies computing an actual difference.
      half_dead = %Node{Node.new(9, 9, :park) | health: 50.0, status: :degraded}
      city = CityMap.put_node(housing_and_parks(4, 3), half_dead)

      assert Calc.metrics(city).amenity_marginal_labour == 2.5
    end
```

Add to `test/armchair_metropolist/domain/entities/simulation_metrics_test.exs`:

```elixir
  test "defaults to no amenity when none is supplied" do
    metrics = SimulationMetrics.build(CityMap.new(40, 30), %{})

    assert metrics.amenity == 1.0
    assert metrics.amenity_marginal_labour == 0.0
  end

  test "carries the amenity figures it is given" do
    metrics =
      SimulationMetrics.build(CityMap.new(40, 30), %{}, %{
        amenity: 1.75,
        amenity_marginal_labour: 5.0
      })

    assert metrics.amenity == 1.75
    assert metrics.amenity_marginal_labour == 5.0
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
mix test test/armchair_metropolist/domain/entities/simulation_metrics_test.exs test/armchair_metropolist/domain/services/simulation_calculator_test.exs
```

Expected: FAIL with `key :amenity not found` / `undefined function build/3`.

- [ ] **Step 3: Add the fields to `SimulationMetrics`**

In `lib/armchair_metropolist/domain/entities/simulation_metrics.ex`, extend the type, add the default, extend the struct, and change `build`:

```elixir
  @type t :: %__MODULE__{
          tick: non_neg_integer(),
          resources: %{optional(atom()) => resource_stats()},
          node_count: non_neg_integer(),
          avg_health: float(),
          offline_count: non_neg_integer(),
          by_type: %{Node.node_type() => type_stats()},
          money: float(),
          amenity: float(),
          amenity_marginal_labour: float()
        }

  # A city with no parks has no amenity, so the identity multiplier and a zero marginal
  # are the correct values rather than filler. The default exists because `build/2` has
  # a dozen call sites in tests; the one production caller,
  # `Domain.Services.SimulationCalculator.metrics/1`, always passes real figures, and a
  # test on that wiring is what stops this default reaching a player.
  @default_amenity %{amenity: 1.0, amenity_marginal_labour: 0.0}

  defstruct tick: 0,
            resources: %{},
            node_count: 0,
            avg_health: 0.0,
            offline_count: 0,
            by_type: %{},
            money: 0.0,
            amenity: 1.0,
            amenity_marginal_labour: 0.0
```

Change `build/2` to `build/3`, keeping the body otherwise identical:

```elixir
  @doc """
  Build a SimulationMetrics struct from a city map, resource statistics and the city's
  park amenity.

  `amenity` carries `:amenity` (the multiplier on labour supply) and
  `:amenity_marginal_labour` (what one more park would add to it). Both are computed by
  `Domain.Services.SimulationCalculator`, which this module cannot call — `Domain` has
  `deps: []` — so they arrive as an argument rather than being derived here.
  """
  def build(city_map, resources, amenity \\ @default_amenity) do
    nodes = CityMap.nodes(city_map)
    node_count = length(nodes)

    avg_health = calculate_avg_health(nodes)
    offline_count = count_offline_nodes(nodes)

    %__MODULE__{
      tick: city_map.tick,
      resources: resources,
      node_count: node_count,
      avg_health: avg_health,
      offline_count: offline_count,
      by_type: build_by_type(nodes),
      money: city_map.money,
      amenity: Map.fetch!(amenity, :amenity),
      amenity_marginal_labour: Map.fetch!(amenity, :amenity_marginal_labour)
    }
  end
```

`Map.fetch!/2`, not `Map.get/3`: a caller passing a half-filled map is a bug and should say so at the call site rather than silently defaulting.

- [ ] **Step 4: Wire it up in `metrics/1`**

In `lib/armchair_metropolist/domain/services/simulation_calculator.ex`, replace `metrics/1` and add the two helpers:

```elixir
  @doc """
  Build the aggregate metrics for the city in its current state.
  """
  @spec metrics(CityMap.t()) :: SimulationMetrics.t()
  def metrics(city_map) do
    nodes = CityMap.nodes(city_map)

    amenity = %{
      amenity: labour_multiplier(nodes),
      amenity_marginal_labour: marginal_amenity_labour(nodes)
    }

    SimulationMetrics.build(city_map, resource_stats(city_map), amenity)
  end
```

```elixir
  # What one more park would add to labour supply, computed as an actual difference
  # rather than as the constant `4k` the algebra predicts. The two agree everywhere
  # except where the extra park takes the ratio across the cap, and there only the
  # difference is right.
  #
  # The probe park's coordinates are arbitrary. `total_supply/1` reduces over a list and
  # never reads position or identity, so a duplicate id cannot collide here — but this
  # list must not be put back into a CityMap.
  defp marginal_amenity_labour(nodes) do
    labour_supply([Node.new(0, 0, :park) | nodes]) - labour_supply(nodes)
  end

  defp labour_supply(nodes), do: nodes |> total_supply() |> Map.fetch!(:labour)
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
mix test test/armchair_metropolist/domain/entities/simulation_metrics_test.exs test/armchair_metropolist/domain/services/simulation_calculator_test.exs
```

Expected: PASS.

- [ ] **Step 6: Run the full suite**

```bash
mix test
```

Expected: no failures. Every existing `build/2` call site still compiles against the default.

- [ ] **Step 7: Mutation-verify**

1. In `metrics/1`, pass `%{amenity: 1.0, amenity_marginal_labour: 0.0}` instead of the computed map → "metrics carries the multiplier" fails. This is the test that stops the default silently reaching production. Restore.
2. Replace `marginal_amenity_labour/1`'s body with the constant `5.0` → "the true difference where a park crosses the cap" fails while the other two marginal tests still pass, which is exactly why that test exists. Restore.

- [ ] **Step 8: Commit**

```bash
git add lib/armchair_metropolist/domain/entities/simulation_metrics.ex lib/armchair_metropolist/domain/services/simulation_calculator.ex test/armchair_metropolist/domain/entities/simulation_metrics_test.exs test/armchair_metropolist/domain/services/simulation_calculator_test.exs
git commit -m "feat(domain): carry amenity figures on SimulationMetrics

The web layer cannot reach Domain.Services and SimulationMetrics cannot reach it
either (Domain has deps: []), so metrics/1 computes the multiplier and the
marginal labour and passes them into build/3.

amenity_marginal_labour is a real difference rather than the constant L*k, because
the two disagree where an added park crosses the ratio cap."
```

---

## Task 4: Show the amenity in the legend and metrics

**Files:**
- Modify: `lib/armchair_metropolist_web/live/simulator_live.ex` — `legend/1` call site, `resource_cell/1`, `marginal_cell/2`, `metrics/1`
- Modify: `test/armchair_metropolist_web/live/simulator_live_test.exs`

**Interfaces:**
- Consumes: `@metrics.amenity` and `@metrics.amenity_marginal_labour` from Task 3; `Node.consumption(:park)[:labour]` from Task 1.
- Produces: `#metrics-amenity` element; `[data-cell="park-labour"]` shows a signed net figure.

- [ ] **Step 1: Write the failing tests**

Add to `test/armchair_metropolist_web/live/simulator_live_test.exs`. Define the helper once near the other private helpers at the bottom of the file:

```elixir
  defp place(view, type, x, y) do
    view
    |> element(~s{button[phx-click="select_type"][phx-value-type="#{type}"]})
    |> render_click()

    view
    |> element(~s{[phx-click="place"][phx-value-x="#{x}"][phx-value-y="#{y}"]})
    |> render_click()
  end
```

Then, in the legend describe block:

```elixir
    test "park's labour cell shows the amenity net of the park's own staffing" do
      {:ok, view, _html} = live(conn, ~p"/")

      place(view, :residential, 1, 1)
      place(view, :residential, 2, 1)
      place(view, :park, 3, 1)

      # 2 housing, 1 park is ratio 0.5, below the cap: one more park adds L*k = 5 labour
      # and draws 1 of its own.
      assert view |> element(~s{[data-cell="park-labour"]}) |> render() =~ "+4"
      assert view |> element("#metrics-amenity") |> render() =~ "1.5"
    end

    test "past parity park's labour cell goes negative" do
      {:ok, view, _html} = live(conn, ~p"/")

      place(view, :residential, 1, 1)
      place(view, :park, 2, 1)
      place(view, :park, 3, 1)

      # 1 housing, 2 parks: already past the cap, so another park adds no amenity at
      # all and still draws its 1 labour. Over-provisioning costs rather than merely
      # failing to help.
      assert view |> element(~s{[data-cell="park-labour"]}) |> render() =~ "-1"
    end

    test "staffed types other than park render through the ordinary consumption path" do
      {:ok, view, _html} = live(conn, ~p"/")

      place(view, :transit_hub, 1, 1)
      place(view, :power_plant, 2, 1)

      assert view |> element(~s{[data-cell="transit_hub-labour"]}) |> render() =~ "-2"
      assert view |> element(~s{[data-cell="power_plant-labour"]}) |> render() =~ "-1"
    end

    test "a type that does not touch a resource still renders an em dash" do
      {:ok, view, _html} = live(conn, ~p"/")

      # Positive case first, so this cannot pass against a page rendering em dashes
      # everywhere: power plants do draw water, and that cell is a real number.
      assert view |> element(~s{[data-cell="power_plant-water"]}) |> render() =~ "-20"

      # The park special case must not leak into the general path. `power_plant` draws
      # labour now, so pick a genuinely untouched pair: it produces no money.
      assert view |> element(~s{[data-cell="power_plant-money"]}) |> render() =~ "—"
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
mix test test/armchair_metropolist_web/live/simulator_live_test.exs
```

Expected: the first three FAIL. `park-labour` currently renders `-1` for every state (park draws 1 labour and the amenity is invisible to the cell), and `#metrics-amenity` does not exist. Note the second test may pass for the wrong reason at this point — that is what Step 6's mutation check is for.

- [ ] **Step 3: Thread the marginal figure into the cell**

In `lib/armchair_metropolist_web/live/simulator_live.ex`, at the `legend/1` call site inside `render/1`, add the attribute:

```heex
              <.resource_cell
                :for={resource <- @resources}
                :if={@detail}
                type={type}
                resource={resource}
                stats={@metrics.by_type[type]}
                amenity_marginal_labour={@metrics.amenity_marginal_labour}
              />
```

Add the attr and pass it through:

```elixir
  attr :type, :atom, required: true
  attr :resource, :atom, required: true
  attr :stats, :map, required: true
  attr :amenity_marginal_labour, :float, required: true

  defp resource_cell(assigns) do
    assigns =
      assigns
      |> assign(
        :marginal,
        marginal_cell(assigns.type, assigns.resource, assigns.amenity_marginal_labour)
      )
      |> assign(:total, total_cell(assigns.stats, assigns.resource))
```

- [ ] **Step 4: Add the park clause to `marginal_cell`**

Insert this clause **above** the existing one, and add the third parameter to the existing head:

```elixir
  # `park`'s labour effect is a multiplier on supply, so it appears in neither table and
  # the general clause below would render an em dash — "does not interact with this
  # resource at all", which would be a lie about the one type that drives labour hardest.
  #
  # This still answers the question the function promises, "what one more block of this
  # type would do": the amenity another park would add, net of the labour it would draw.
  # Past parity that is negative, which is the honest figure — over-provisioning parks
  # costs labour rather than merely stopping helping.
  defp marginal_cell(:park, :labour, amenity_marginal_labour) do
    signed(amenity_marginal_labour - Map.get(Node.consumption(:park), :labour, 0.0))
  end

  defp marginal_cell(type, resource, _amenity_marginal_labour) do
    produced = Map.get(Node.production(type), resource)
    consumed = Map.get(Node.consumption(type), resource)

    if is_nil(produced) and is_nil(consumed) do
      "—"
    else
      signed((produced || 0.0) - (consumed || 0.0))
    end
  end
```

Then correct the comment above `marginal_cell`, which currently promises more than the function now delivers. Replace:

```
  # Rated, deliberately. A newly placed node starts at full health, so its contribution
  # *is* its rated figure. Taken from the domain's own tables rather than from `by_type`
  # because this is a property of the type, fixed, not of the current city.
```

with:

```
  # Rated, deliberately. A newly placed node starts at full health, so its contribution
  # *is* its rated figure. Taken from the domain's own tables rather than from `by_type`
  # because this is a property of the type.
  #
  # One exception, and it is signposted in the clause itself: `{:park, :labour}` depends
  # on the current city. The park amenity is a multiplier, so its *magnitude* is fixed at
  # `4k` by the arithmetic, but whether the city has already reached the ratio cap is
  # city state — and past the cap the honest figure changes sign.
```

- [ ] **Step 5: Add the metrics line**

In the `metrics/1` component, after the treasury line:

```heex
      <p id="metrics-amenity">Amenity: ×{Float.round(@metrics.amenity, 2)}</p>
```

Two decimals, not one: the ratio is continuous, and 7 housing with 3 parks is ×1.43, which one decimal would collapse into its neighbours.

- [ ] **Step 6: Run the tests to verify they pass**

```bash
mix test test/armchair_metropolist_web/live/simulator_live_test.exs
```

Expected: PASS.

- [ ] **Step 7: Mutation-verify**

1. Drop the netting — `signed(amenity_marginal_labour)` → "shows the amenity net of the park's own staffing" fails (`+5`, not `+4`) and "past parity goes negative" fails (`+0`, not `-1`). Both must go red; if only one does, the second test is passing for the wrong reason. Restore.
2. Change `Float.round(@metrics.amenity, 2)` to `round(@metrics.amenity)` → the `1.5` assertion fails. Restore.
3. Delete the `{:park, :labour}` clause → the em dash test still passes and the first two fail, confirming the special case is scoped. Restore.

- [ ] **Step 8: Verify in the browser**

The spec asks for this because the sidebar is `min-w-fit` and any content wider than the current maximum silently moves both wrap thresholds.

Start the dev server with the Browser pane (never `mix phx.server` via Bash), place two residential and one park, then confirm:

- `#metrics-amenity` reads `Amenity: ×1.5`;
- `[data-cell="park-labour"]` reads `+3`;
- the page body does not scroll horizontally, and the legend still sits beside the grid at a wide viewport.

If the sidebar's width has grown, re-measure both `max-[Npx]` thresholds by the procedure in `render/1`'s comment — binary-search the real viewport in each collapse state and take each window's midpoint. Do not compute them from the old values.

- [ ] **Step 9: Commit**

```bash
git add lib/armchair_metropolist_web/live/simulator_live.ex test/armchair_metropolist_web/live/simulator_live_test.exs
git commit -m "feat(web): show the park amenity in the legend and metrics

Park's labour cell shows what one more park would do — the amenity it adds, net
of the labour it draws — so +4 below the ratio cap and -1 past it. An em dash
there would have claimed park does not touch labour, which is the opposite of
true.

Metrics gains an Amenity line, at two decimals because the ratio is continuous."
```

---

## Task 5: Document the rule

**Files:**
- Modify: `test/support/playing_guide.ex` — `constants_block/0` and three measured helpers
- Modify: `docs/PLAYING.md` — regenerated `constants` block, plus three prose passages

**Interfaces:**
- Consumes: everything above.
- Produces: nothing consumed by later tasks. This is the last task.

- [ ] **Step 1: Add the measured amenity helpers**

In `test/support/playing_guide.ex`, in the "measured, not copied" section. Derived from observed behaviour rather than read from the calculator's attributes, matching how `regen_rate/0` and `decay_rate/0` already work:

```elixir
  # Two housing and one park is ratio 0.5 — below the cap — so the fractional gain in
  # labour supply over the same city with no park is `k * 0.5`. Solve for k. (Two housing
  # supply 10.0 unparked and 15.0 with the park, so this reads (1.5 - 1) / 0.5 = 1.0.)
  defp amenity_coefficient do
    base = labour_supplied(city_with(residential: 2))
    parked = labour_supplied(city_with(residential: 2, park: 1))

    Float.round((parked / base - 1.0) / 0.5, 4)
  end

  # The ratio at which more parks stop adding labour. Scanned rather than restated, so
  # a change to the cap moves the guide.
  defp amenity_cap_ratio do
    housing = 4

    Enum.find_value(1..40, fn parks ->
      here = labour_supplied(city_with(residential: housing, park: parks))
      next = labour_supplied(city_with(residential: housing, park: parks + 1))

      if here == next, do: Float.round(parks / housing, 4)
    end)
  end

  # Far past the cap, so this is the ceiling itself rather than a point on the way up.
  defp amenity_ceiling do
    base = labour_supplied(city_with(residential: 2))

    Float.round(labour_supplied(city_with(residential: 2, park: 20)) / base, 4)
  end

  defp labour_supplied(city) do
    city |> Calc.resource_stats() |> Map.fetch!(:labour) |> Map.fetch!(:supplied)
  end
```

- [ ] **Step 2: Add the two rows to `constants_block/0`**

Insert after the decay row:

```elixir
        "| labour supply, multiplied per park per housing block | **+#{num(amenity_coefficient())} × (parks ÷ housing)** |",
        "| that multiplier's ceiling, at #{num(amenity_cap_ratio())} park per housing block | **×#{num(amenity_ceiling())}** |",
```

- [ ] **Step 3: Regenerate and check the values**

```bash
REGENERATE_PLAYING_GUIDE=1 mix test test/docs/playing_guide_test.exs
git --no-pager diff --no-ext-diff docs/PLAYING.md
```

Expected: two new rows reading exactly

```
| labour supply, multiplied per park per housing block | **+1 × (parks ÷ housing)** |
| that multiplier's ceiling, at 1 park per housing block | **×2** |
```

If either shows a fraction, a measurement helper is wrong — fix the helper, not the document.

- [ ] **Step 4: Rewrite the park paragraph**

In `docs/PLAYING.md`, replace this paragraph in the consumption reference:

```markdown
`park` is usually a trap — it trades a lot of water for a little waste capacity, so it
only pays when you have spare water and are waste-limited, which is rare given how much
`industrial` supplies.
```

with:

```markdown
`park` is how you get more workers out of the housing you already have. It produces no
labour itself — a city with no residential blocks has no workforce for a park to
amplify — but each one raises the labour your housing supplies, up to **one park per
residential block**, where the bonus stops at double. Past that ratio a park is pure
cost: it still drinks 18 water, still needs a groundskeeper, and adds nothing. The
legend's labour column tells you which side of that line you are on, showing `+4` while
parks are worth building and `-1` once they are not.

Parks are thirsty, and that is what bounds them. Two is the most the free baseline's 40
water will carry, so scaling beyond that means water plants, which need power. A
neglected park is worse than none: amenity is scaled by health, its staffing and water
draw are not, so a dead park amplifies nothing while still costing everything.
```

- [ ] **Step 5: Extend the min-residential explanation**

Replace:

```markdown
The min residential column exists for the same reason the max one does, just at the other
end: `industrial` and `commercial` need workers, and residential is the only source of
labour, so build the support set with too few residential and those blocks starve for
staff instead of power or water — the shortfall just shows up in a different column.
```

with:

```markdown
The min residential column exists for the same reason the max one does, just at the other
end: **every block needs staff except the homes the staff live in**. Power plants, water
plants, transit hubs, parks, industry and commerce all draw labour, and residential is the
only thing that supplies it — so build a support set with too few homes and those blocks
starve for staff instead of power or water, and the shortfall just shows up in a different
column.
```

- [ ] **Step 6: Add the double-decay note to the rescue section**

Append to the "Rescuing a city that is already dying" section, after the two numbered approaches:

```markdown
**Labour comes back more slowly than the housing count suggests.** Amenity is scaled by
health on both sides, so a damaged city loses workforce twice over: its residential
blocks produce less labour, *and* its parks multiply what remains by less — while both
keep drawing their full demand. Expect the labour column to lag the others during a
rescue, and read the *Amenity* line in the metrics rather than counting parks on the
grid.
```

- [ ] **Step 7: Verify the guide test still passes**

```bash
mix test test/docs/playing_guide_test.exs
```

Expected: PASS. Prose edits sit outside the generated markers, so they cannot break it — if this fails, an edit landed inside a `<!-- generated:... -->` block. Move it out.

- [ ] **Step 8: Run the full gate**

```bash
mix check
```

Expected: exit 0, coverage at or above the 90% threshold. If coverage dropped below it, the likely gap is an unexercised branch in `labour_multiplier/1` — the `housing > 0.0` false branch is covered by Task 2's "no housing" test, so check that it survived.

- [ ] **Step 9: Commit**

```bash
git add test/support/playing_guide.ex docs/PLAYING.md
git commit -m "docs: document the park amenity in the playing guide

Two generated constants rows, measured out of observed labour supply rather than
read from the calculator's attributes, matching how the decay and regeneration
rates are already derived.

Rewrites the park paragraph: it stops being 'usually a trap' and becomes a
description of provision, including the sign change past one park per housing
block. Adds transit hubs and parks to the list of types that need staff, and
notes that amenity decays twice over during a collapse."
```

---

## Self-Review

**Spec coverage.** Every section of the spec maps to a task: §2 the rule → Task 2; §3 staffing → Task 1; §4's constants → Task 2 (values) and Task 5 (documenting them); §5 implementation → Tasks 2 and 3; §6 presentation → Task 4; §7 rejected alternatives → nothing to build; §8 accepted consequences → Task 1 Steps 7–9 handle the support-set loss, and the housing-erosion and over-build consequences are documented in Task 5; §9 documentation → Tasks 1 and 5; §10 testing → distributed across every task's test step.

**One spec item deliberately not implemented here.** §8 notes that the construction-costs spec's balance figures are invalidated by this change — the smallest viable city moves from 445 to 530, above the 500 grant. That is recorded in both specs and belongs to the construction-costs branch, which lands second. Nothing in this plan should touch `CityMap`'s opening grant.

**Type consistency.** `labour_multiplier/1` and `labour_supply/1` both take a **list of nodes**, not a `CityMap` — Task 3 calls them with `CityMap.nodes(city_map)`. `build/3`'s third argument is a map keyed `:amenity` and `:amenity_marginal_labour`, matching the struct field names exactly so there is no translation layer. `amenity_marginal_labour` is the **supply-side delta only** throughout; the netting against park's own labour happens once, in Task 4's `marginal_cell/3` clause. Task 4 changes `marginal_cell` from arity 2 to arity 3 and updates its only caller in the same step.

**A test passing is not the same as a fixture being unaffected.** Task 1 Step 6b exists because `sub_rounding_city`'s test passes after staffing while three of its five nodes silently change from stable to decaying. It was found by asking why, not by reading the suite result — the suite said `254 passed` both before and after. When a data change touches a resource, check the fixtures that *pass*, not only the ones that fail: a fixture whose assertions name specific node ids will absorb an arbitrary amount of unrelated change.

**Verified rather than assumed.** Task 1's code, its **seven** expected failures, all four fixture re-derivations (including the two re-solved water-plant healths, 41.7 and 34.5333) and the exact `docs/PLAYING.md` diff were produced by applying the whole change, fixing every failure, running the suite green at 254, and then restoring the tree. Tasks 2–5 are designed but not trial-run; their expected values are arithmetically verified against the rule, including that every float equality holds exactly at `L = 5`.

**What the second amendment changed in this plan.** Task 1 grew from two table entries to five and from three failures to seven, `@support_sets` moved from "edit it" to "do not touch it", and every expected value in Tasks 2–4 shifted because `L` went from 4 to 5 — the identity is now `LH + LkP`, the gross bonus per park is 5, and the legend cell reads `+4`. If you find a `4` where a `5` belongs, or an instruction to drop a support set, it is a leftover from the first amendment. Task 2's expected arithmetic (`24.0`, `48.0`, `40.0`, `32.0`, `2.0`) was computed from the rule directly. Tasks 3–5 are designed but not trial-run; treat their expected values as predictions to check, not guarantees.
