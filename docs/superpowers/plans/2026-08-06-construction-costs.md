# Construction Costs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make building and demolishing spend money, so what a player can build is bounded by what the city has earned.

**Architecture:** A third lookup table in `Node` holds per-type construction costs beside the existing production and consumption tables, plus one flat demolition constant. `UseCases.ManageInfrastructure.place/4` and `demolish/3` gate on the treasury and debit it — in the Domain, where a test can reach them without a running GenServer. The charge is a withdrawal from a stock and never enters `resource_stats/1`, so the per-tick economy figures are untouched. Nothing persisted changes shape.

**Tech Stack:** Elixir 1.20.2 / OTP 29, Phoenix LiveView, ExUnit + StreamData, `boundary` compiler, `mix check`.

**Spec:** `docs/superpowers/specs/2026-08-05-construction-costs-design.md`

## Global Constraints

- **The cost table** is `power_plant: 80.0`, `water_plant: 70.0`, `industrial: 60.0`, `transit_hub: 40.0`, `commercial: 40.0`, `park: 20.0`, `residential: 15.0`. Demolition is a flat **10.0** for every type.
- **Demolition must stay strictly below the cheapest construction cost**, enforced by a test, not by convention.
- **Every cost is a whole number.** The legend's `signed/1` and the treasury's display both round, so a fractional cost would render a figure the engine does not charge. This is also what makes the floored treasury display consistent with the exact comparison (see below).
- **The opening grant is 150.0**, stated **once** as `@opening_grant` in `CityMap` and exposed via `opening_grant/0`. It is currently stated twice — in `defstruct` and again in `new/2` — and `CityEngine.normalize_city_map/1` merges decoded snapshots onto `%CityMap{}`, so the struct default is what an old city inherits while `new/2`'s literal is what a fresh one gets. Changing one and not the other desyncs them on a path only cold loads exercise.
- **The treasury renders floored (`trunc/1`), never rounded.** A balance of 79.6 displaying as 80 while an 80-cost build is refused is a cell contradicting itself. Because every cost is a whole number, `trunc(money) >= cost` exactly when `money >= cost`, which is what keeps display and behaviour consistent.
- **The domain comparison is exact — no epsilon.** There is no rounding downstream of it, and a tolerance would permit a build that drives the balance below zero, breaking the no-debt invariant.
- **The charge must never enter `demanded(:money)`.** It is a withdrawal from a stock, not a per-tick flow. Folding it in would corrupt the legend's totals cell and re-create the self-contradicting cell the money design's 2026-08-02 amendment exists to fix.
- **No debt.** The balance keeps its `max(0.0, …)` floor; an unaffordable command is refused, not financed.
- **No "reset city" control.** Deferred by explicit decision, despite §8's dead end. Do not build one.
- Test discipline, non-negotiable: every new test must be seen to **fail** before it is trusted. Never write a `refute` without asserting the positive case first.
- **Do not restore a file with `git checkout`** when mutation-testing. Use an inverse edit or a copy you made first — `git checkout` has destroyed uncommitted work in this repo before.
- `mix check` must exit 0 before the final commit (format, compile with warnings-as-errors, sobelow, deps.audit, suite under a 90% coverage gate).
- **Baseline:** `mix test` reports `280 passed (5 properties, 275 tests)`, coverage 95.11%. The `[reaper] sweep failed … ArithmeticError` warnings are pre-existing deliberate error-injection noise.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `lib/armchair_metropolist/domain/entities/node.ex` | Modify: add `@construction_cost_table`, `@demolition_cost` and their accessors | 1 |
| `test/armchair_metropolist/domain/entities/node_test.exs` | Modify: cost table assertions, coverage gate, demolition invariant | 1 |
| `lib/armchair_metropolist/domain/entities/city_map.ex` | Modify: `@opening_grant` + `opening_grant/0` (Task 2); `debit/2` (Task 3) | 2, 3 |
| `test/armchair_metropolist/domain/entities/city_map_test.exs` | Modify: grant and `debit/2` tests | 2, 3 |
| `test/armchair_metropolist/infrastructure/simulation/city_engine_test.exs` | Modify: grant assertion (Task 2); rich-snapshot seeding for `starve/1` callers, plus two broadcast tests (Task 3) | 2, 3 |
| `test/armchair_metropolist/domain/services/simulation_calculator_test.exs` | Modify: the `502.0` assertion and a stale comment (Task 2); the charge-not-a-flow test (Task 3) | 2, 3 |
| `test/support/playing_guide.ex` | Modify: stale grant comment (Task 2); `costs` block (Task 6) | 2, 6 |
| `README.md` | Modify: the one-off grant figure | 2 |
| `lib/armchair_metropolist/use_cases/manage_infrastructure.ex` | Modify: the affordability gates and the debits | 3 |
| `test/armchair_metropolist/use_cases/manage_infrastructure_test.exs` | Modify: gate, debit, ordering and property tests; the round-trip test's identity assertion | 3 |
| `lib/armchair_metropolist/infrastructure/simulation/city_engine.ex` | Modify: `place/4` and `demolish/3` `@spec` error unions only — no behaviour change | 3 |
| `lib/armchair_metropolist_web/live/simulator_live.ex` | Modify: floored treasury + refusal flash (Task 4); cost column, dimming and the totals-row `colspan` (Task 5) | 4, 5 |
| `test/armchair_metropolist_web/live/simulator_live_test.exs` | Modify: `setup`'s snapshot seeding + the `treasury` tag (Task 4); grant assertion and the two multi-plant fixtures (Tasks 2, 3); flash, floored treasury, cost column, affordability | 2, 3, 4, 5 |
| `docs/PLAYING.md` | Add the `costs` marker and block; rewrite six prose passages | 6 |

---

## Task 1: Prices in `Node`

**Files:**
- Modify: `lib/armchair_metropolist/domain/entities/node.ex` (after `@consumption_table`)
- Modify: `test/armchair_metropolist/domain/entities/node_test.exs`

**Interfaces:**
- Consumes: nothing.
- Produces: `Node.construction_cost(node_type()) :: float()` (raises `KeyError` on an unknown type — that is deliberate and load-bearing for Task 3's clause ordering) and `Node.demolition_cost() :: float()`. Tasks 3, 4, 5 and 6 all call these.

- [ ] **Step 1: Write the failing tests**

Add to `test/armchair_metropolist/domain/entities/node_test.exs`, in the same describe block as the existing table tests:

```elixir
    test "match the specified construction cost table" do
      assert Node.construction_cost(:power_plant) == 80.0
      assert Node.construction_cost(:water_plant) == 70.0
      assert Node.construction_cost(:industrial) == 60.0
      assert Node.construction_cost(:transit_hub) == 40.0
      assert Node.construction_cost(:commercial) == 40.0
      assert Node.construction_cost(:park) == 20.0
      assert Node.construction_cost(:residential) == 15.0
    end

    test "every type has a construction cost" do
      # Mirrors the `Map.keys(baseline_capacity()) == Node.resources()` gate in
      # simulation_calculator_test.exs, and for the same reason: construction_cost/1 is a
      # Map.fetch!, so a type missing from the table raises at runtime instead of failing
      # a test.
      for type <- Node.types() do
        assert is_float(Node.construction_cost(type)), "#{type} has no construction cost"
      end
    end

    test "demolition is flat, and cheaper than building anything" do
      cheapest = Node.types() |> Enum.map(&Node.construction_cost/1) |> Enum.min()

      assert Node.demolition_cost() == 10.0

      assert Node.demolition_cost() < cheapest,
             "demolition (#{Node.demolition_cost()}) must stay below the cheapest " <>
               "construction cost (#{cheapest}), or tearing down becomes the expensive option"
    end

    test "every cost is a whole number" do
      # The legend's `signed/1` and the treasury's display both truncate or round, so a
      # fractional cost would render a figure the engine does not charge. It is also what
      # makes `trunc(money) >= cost` agree with `money >= cost` exactly.
      for type <- Node.types() do
        cost = Node.construction_cost(type)
        assert cost == Float.round(cost), "#{type}'s cost #{cost} is not a whole number"
      end

      assert Node.demolition_cost() == Float.round(Node.demolition_cost())
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
mix test test/armchair_metropolist/domain/entities/node_test.exs
```

Expected: all four FAIL with `undefined function Node.construction_cost/1` and `Node.demolition_cost/0`.

- [ ] **Step 3: Add the tables and accessors**

In `lib/armchair_metropolist/domain/entities/node.ex`, after `@consumption_table`:

```elixir
  # What each type costs to build. A third table beside production and consumption, so
  # every price a player pays lives in one module.
  #
  # Ordered by the block's weight in the city, so the curve reads as
  # infrastructure-is-expensive. Whole numbers throughout — see `cost` in the tests: the
  # legend and the treasury line both truncate, so a fractional cost would render a
  # figure the engine does not charge.
  @construction_cost_table %{
    power_plant: 80.0,
    water_plant: 70.0,
    industrial: 60.0,
    transit_hub: 40.0,
    commercial: 40.0,
    park: 20.0,
    residential: 15.0
  }

  # Flat across every type, and strictly below the cheapest construction cost. Flat
  # because teardown does not care what stood there; below the cheapest because putting a
  # block up is the larger undertaking.
  #
  # `node_test.exs` enforces that second property rather than trusting it: without the
  # test, a later balance patch dropping `residential` to 8 would silently make tearing
  # down the expensive option and nothing in the suite would notice.
  @demolition_cost 10.0
```

and, beside the other accessors:

```elixir
  @doc """
  What it costs to build one node of `node_type`.

  Raises `KeyError` for an unknown type, deliberately: callers validate the type before
  reaching here (see `UseCases.ManageInfrastructure.place/4`, where that clause ordering
  is load-bearing), and a silent default would let an unknown type be built for free.
  """
  @spec construction_cost(node_type()) :: float()
  def construction_cost(node_type) do
    Map.fetch!(@construction_cost_table, node_type)
  end

  @doc """
  What it costs to demolish a node, whatever its type.
  """
  @spec demolition_cost() :: float()
  def demolition_cost, do: @demolition_cost
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
mix test test/armchair_metropolist/domain/entities/node_test.exs
```

Expected: PASS. Then `mix test` — expected `284 passed`, no failures (nothing reads these yet).

- [ ] **Step 5: Mutation-verify**

Break each, confirm the named test reddens, restore by inverse edit (**never** `git checkout`):

1. `@demolition_cost 20.0` → "demolition is flat, and cheaper than building anything" fails (20.0 is above `residential`'s 15.0).
2. `residential: 15.5` → "every cost is a whole number" fails, and so does the table test.
3. Delete `park` from the table → "every type has a construction cost" fails with a `KeyError`, which is the failure mode that test exists to convert into a red assertion.

- [ ] **Step 6: Commit**

```bash
git add lib/armchair_metropolist/domain/entities/node.ex test/armchair_metropolist/domain/entities/node_test.exs
git commit -m "feat(domain): give every node type a construction cost

A third table beside production and consumption, plus a flat demolition cost of
10 held strictly below the cheapest build. The invariant is enforced by a test
rather than convention, so a later balance patch cannot silently make tearing
down the expensive option.

construction_cost/1 raises on an unknown type on purpose — a silent default
would let an unknown type be built for free."
```

---

## Task 2: The grant becomes one constant, and drops to 150

**Files:**
- Modify: `lib/armchair_metropolist/domain/entities/city_map.ex`
- Modify: `test/armchair_metropolist/domain/entities/city_map_test.exs`
- Modify: `test/armchair_metropolist/infrastructure/simulation/city_engine_test.exs`
- Modify: `test/armchair_metropolist/domain/services/simulation_calculator_test.exs` (**a real assertion and a comment** — see Step 4)
- Modify: `test/armchair_metropolist_web/live/simulator_live_test.exs` (one assertion)
- Modify: `README.md` (one figure)
- Modify: `test/support/playing_guide.ex` (a stale comment only — **not** `@support_sets`)

**Interfaces:**
- Consumes: nothing.
- Produces: `CityMap.opening_grant() :: float()` returning `150.0`, and a `%CityMap{}` whose `money` default is that same constant. Task 6 renders it into the guide.

- [ ] **Step 1: Write the failing test**

Add to `test/armchair_metropolist/domain/entities/city_map_test.exs`:

```elixir
  describe "opening_grant/0" do
    test "is the money a new city starts with, from one constant" do
      # All three paths must agree. They are three because `CityEngine.normalize_city_map/1`
      # merges a decoded snapshot onto `%CityMap{}` — so the struct default is what an old
      # city inherits, while `new/2` is what a fresh one gets. Stating the figure twice
      # (as this module used to) desyncs them on a path only cold loads exercise.
      assert CityMap.opening_grant() == 150.0
      assert CityMap.new(40, 30).money == CityMap.opening_grant()
      assert %CityMap{}.money == CityMap.opening_grant()
    end
  end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
mix test test/armchair_metropolist/domain/entities/city_map_test.exs
```

Expected: FAIL with `undefined function CityMap.opening_grant/0`.

- [ ] **Step 3: Make the grant one constant**

In `lib/armchair_metropolist/domain/entities/city_map.ex`, above `defstruct`:

```elixir
  # The money a new city starts with, stated once. It used to appear twice — here and
  # again in `new/2` — and `CityEngine.normalize_city_map/1` merges a decoded snapshot
  # onto `%CityMap{}`, so this default is what an old city inherits while `new/2`'s
  # literal was what a fresh one got. Changing one and not the other desynced them on a
  # path only cold loads exercise.
  #
  # 150 rather than the original 500: the park amenity lowered the cheapest viable
  # earning city to 75 — one commercial, one park and one house, measured stable at
  # +28/tick — so 500 bought the minimum six times over. See the construction-costs
  # design, §7.
  @opening_grant 150.0
```

Change `defstruct` to use it, and delete `money:` from `new/2`'s struct literal entirely so the default is the single source:

```elixir
  defstruct width: 40, height: 30, tick: 0, nodes: %{}, money: @opening_grant
```

```elixir
  def new(width, height) do
    %__MODULE__{
      width: width,
      height: height,
      tick: 0,
      nodes: %{}
    }
  end
```

Add the accessor:

```elixir
  @doc """
  The money a new city starts with.

  Public so tests and the playing-guide generator reference the figure instead of
  restating it. Six readers across four files pinned the old literal, and one of them
  pinned it *derived* — an assertion on 502.0, the grant plus two ticks of income, which
  a search for the grant's own value does not find.
  """
  @spec opening_grant() :: float()
  def opening_grant, do: @opening_grant
```

- [ ] **Step 4: Update every reader that pins the old figure**

There are **six**, in four files. Three are live assertions and three are prose. The list below is complete as of this branch's HEAD; before you start, confirm it with

```bash
grep -rn "500\|502\.0" lib test README.md docs/PLAYING.md | grep -v "_build\|deps\|0o500\|error_\|linger\|500ms\|production 500"
```

and report any hit not named here. Note that a plain `500` grep does **not** find the third assertion below — its literal is `502.0`, the grant plus two residential income. Derived figures are the ones that go stale silently.

*Assertions:*

1. `city_engine_test.exs` — `assert loaded.money == 500.0` becomes `assert loaded.money == CityMap.opening_grant()`. Reference the accessor, not a new literal; that is the whole point of adding it. The file already aliases `CityMap`.
2. `simulator_live_test.exs` — `assert view |> element("#metrics-treasury") |> render() =~ "500"` becomes `=~ "150"`. Keep the literal here rather than interpolating the accessor: this test is about the *page* printing the balance, and a literal is what fails loudly if the grant moves again. (After Task 4 the treasury is floored, which does not change a whole-number grant.)
3. `simulation_calculator_test.exs` — `assert advanced.money == 502.0` in "an untouched city keeps its balance across a tick" becomes `152.0`. The comment above it explains the +2 as two residential each producing 1.0; keep that reasoning, it is still correct.

*Prose:*

4. `simulation_calculator_test.exs` — the `sub_rounding_city` comment says money's satisfaction stays at 1.0 only because "`CityMap.new/2`'s default 500.0 grant" covers the demand as `carried`. Still true at 150 — that fixture's money demand is 14 — but the figure is wrong. Change it to 150.0 and keep the reasoning.
5. `test/support/playing_guide.ex` — `city_with/1`'s comment explains why it sets `money: 0.0`: over a 120-tick window a city one short on income drains the grant at 1/tick and survives all 120, so the guide would certify a city that goes bankrupt later. Update the figure, and note that a **smaller** grant makes that trap tighter rather than looser — at 150 a 1/tick shortfall still outlasts the window.
6. `README.md` — "a city opens with a one-off 500 in the treasury" becomes 150. This one is a published claim about the game with no test behind it, which is exactly why it is easy to miss.

Do **not** touch `@support_sets`.

- [ ] **Step 5: Run the full suite**

```bash
mix test
```

Expected: PASS — the three assertions above are the only ones that move. If anything *else* fails because a fixture relied on 500 covering a long money deficit, **report it** — do not raise the grant back. Nothing in the suite is believed to depend on the grant's size, only on its exact value in those three places; a failure beyond them is a real finding and the controller needs to see it.

- [ ] **Step 6: Mutation-verify**

1. Restore `money: 500.0` to `new/2`'s literal while leaving `@opening_grant` at 150.0 → the `new/2` assertion in the new test fails. This is the desync the constant exists to prevent, so seeing it red is the point. Restore.
2. Set `@opening_grant 500.0` → the `== 150.0` assertion fails and `city_engine_test`'s assertion still passes (it reads the accessor). That asymmetry is correct: one test pins the value, the other pins the wiring.

- [ ] **Step 7: Commit**

```bash
git add lib/armchair_metropolist/domain/entities/city_map.ex test/ README.md
git commit -m "feat(domain): state the opening grant once, and drop it to 150

CityMap stated the figure twice, in defstruct and again in new/2, and
normalize_city_map/1 merges decoded snapshots onto %CityMap{} — so the struct
default is what an old city inherits while new/2's literal is what a fresh one
gets. Changing one and not the other desynced them on a path only cold loads
exercise.

150 rather than 500 because the park amenity lowered the cheapest viable earning
city to 75, so 500 bought the minimum six times over.

Six readers pinned the old figure across four files. One of them asserted 502.0 —
the grant plus two residential income — which a grep for 500 does not find."
```

---

## Task 3: The charge

**Files:**
- Modify: `lib/armchair_metropolist/domain/entities/city_map.ex` (add `debit/2`)
- Modify: `lib/armchair_metropolist/use_cases/manage_infrastructure.ex`
- Modify: `test/armchair_metropolist/domain/entities/city_map_test.exs`
- Modify: `test/armchair_metropolist/use_cases/manage_infrastructure_test.exs`

**Interfaces:**
- Consumes: `Node.construction_cost/1`, `Node.demolition_cost/0` (Task 1); `CityMap.opening_grant/0` (Task 2).
- Produces: `place/4` and `demolish/3` gain `{:error, :insufficient_funds}`; `CityMap.debit(map, amount) :: CityMap.t()`. Task 4 matches on that error atom.

- [ ] **Step 1: Write the failing tests**

Add to `test/armchair_metropolist/domain/entities/city_map_test.exs`:

```elixir
  describe "debit/2" do
    test "subtracts from the treasury" do
      map = %{CityMap.new(40, 30) | money: 100.0}

      assert CityMap.debit(map, 30.0).money == 70.0
    end

    test "floors at zero rather than going negative" do
      # Unreachable through `ManageInfrastructure`, which refuses an unaffordable
      # command — the clamp documents that a balance is never negative regardless of
      # caller, which is the invariant the money design calls load-bearing.
      map = %{CityMap.new(40, 30) | money: 5.0}

      assert CityMap.debit(map, 30.0).money == 0.0
    end
  end
```

Add to `test/armchair_metropolist/use_cases/manage_infrastructure_test.exs`, inside the existing `describe "place/4"`:

```elixir
    test "debits the treasury by exactly the type's cost" do
      map = %{CityMap.new(40, 30) | money: 100.0}

      {:ok, {map, _node}} = ManageInfrastructure.place(map, 1, 1, :park)

      assert map.money == 80.0
    end

    test "a balance exactly equal to the cost succeeds and leaves zero" do
      # The test that kills `<` flipped to `<=`. Built from a literal balance rather than
      # a simulated one: a damaged producer yields fractional income, and an exact
      # equality against a simulated balance would be asserting float noise.
      map = %{CityMap.new(40, 30) | money: 20.0}

      assert {:ok, {map, _node}} = ManageInfrastructure.place(map, 1, 1, :park)
      assert map.money == 0.0
    end

    test "refuses an unaffordable build and changes nothing at all" do
      map = %{CityMap.new(40, 30) | money: 19.0}

      assert {:error, :insufficient_funds} = ManageInfrastructure.place(map, 1, 1, :park)

      # Both halves asserted: an implementation that debits and *then* refuses would
      # satisfy the error tuple alone.
      assert map.money == 19.0
      assert map.nodes == %{}
    end

    test "reports occupancy before affordability" do
      # Clause ordering, invisible in review because every clause returns an error
      # tuple. A click on an occupied cell should not report that you are broke about a
      # build that was never possible on that cell.
      {:ok, {map, _}} = ManageInfrastructure.place(CityMap.new(40, 30), 1, 1, :park)
      broke = %{map | money: 0.0}

      assert {:error, :occupied} = ManageInfrastructure.place(broke, 1, 1, :park)
    end

    test "reports an unknown type before affordability, and does not raise" do
      # `construction_cost/1` is a `Map.fetch!`, so an unknown type reaching the cost
      # check raises KeyError inside a GenServer.call instead of returning an error
      # tuple — which takes the engine down and rolls the city back to its last
      # checkpoint. This test is the guard on that clause order.
      broke = %{CityMap.new(40, 30) | money: 0.0}

      assert {:error, :unknown_type} = ManageInfrastructure.place(broke, 1, 1, :airport)
    end
```

and inside `describe "demolish/3"`:

```elixir
    test "debits the flat demolition cost" do
      {:ok, {map, _}} = ManageInfrastructure.place(CityMap.new(40, 30), 1, 1, :park)
      map = %{map | money: 100.0}

      {:ok, {map, _id}} = ManageInfrastructure.demolish(map, 1, 1)

      assert map.money == 90.0
    end

    test "refuses an unaffordable demolition and leaves the node standing" do
      {:ok, {map, _}} = ManageInfrastructure.place(CityMap.new(40, 30), 1, 1, :park)
      map = %{map | money: 9.0}

      assert {:error, :insufficient_funds} = ManageInfrastructure.demolish(map, 1, 1)
      assert map.money == 9.0
      refute CityMap.get_node(map, 1, 1) == nil
    end

    test "reports an empty cell before affordability" do
      broke = %{CityMap.new(40, 30) | money: 0.0}

      assert {:error, :empty} = ManageInfrastructure.demolish(broke, 5, 5)
    end
```

And a test that the charge stays out of the per-tick economy — put it in `test/armchair_metropolist/domain/services/simulation_calculator_test.exs`:

```elixir
    test "a construction charge does not enter money demand" do
      alias ArmchairMetropolist.UseCases.ManageInfrastructure

      before = map_with([Node.new(0, 0, :park)])
      {:ok, {after_place, _}} = ManageInfrastructure.place(before, 1, 1, :park)

      # Positive case first: money demand does track upkeep, so this cannot pass by
      # reading zero out of a broken path. Two parks draw 3 each.
      #
      # The second assertion is the whole test. Exact equality on 6.0 means the 20.0
      # build charge is provably absent — demand is a per-tick flow, the charge is a
      # withdrawal from a stock, and folding it in would corrupt the legend's totals
      # cell, which is the defect the money design's amendment exists to fix. A
      # `refute … == 26.0` alongside it would be decoration: dead the moment the
      # equality above passes.
      assert Calc.resource_stats(before).money.demanded == 3.0
      assert Calc.resource_stats(after_place).money.demanded == 6.0
    end
```

Also fix the existing round-trip test in `manage_infrastructure_test.exs`, which asserts an identity that is no longer true:

```elixir
    test "place then demolish restores the map's nodes, minus what both cost" do
      # No longer `restored == map`: the round trip costs 60 to build an industrial and
      # 10 to tear it down, and that 70 does not come back. Asserting on `nodes` keeps
      # the property the test was written for — teardown leaves no trace on the grid —
      # while naming the money as a separate, deliberate difference.
      {:ok, {placed, _}} = ManageInfrastructure.place(map, 5, 5, :industrial)
      {:ok, {restored, _}} = ManageInfrastructure.demolish(placed, 5, 5)

      assert restored.nodes == map.nodes
      assert restored.money == map.money - 70.0
    end
```

Rename it as shown. Leaving the old name on a test that no longer checks a round trip is worse than either the old test or the new one.

- [ ] **Step 2: Run them to verify they fail**

```bash
mix test test/armchair_metropolist/domain/entities/city_map_test.exs test/armchair_metropolist/use_cases/manage_infrastructure_test.exs test/armchair_metropolist/domain/services/simulation_calculator_test.exs
```

Expected: the `debit/2` tests fail on `undefined function`; the `place/4` and `demolish/3` money tests fail because no charge exists yet; the ordering tests may already pass (the existing clauses happen to be in the right order) — note that in your report rather than contriving failures.

- [ ] **Step 3: Add `CityMap.debit/2`**

```elixir
  @doc """
  Subtract `amount` from the city's treasury, flooring at zero.

  A one-line function rather than an inline `%{map | money: …}` so the floor-at-zero rule
  lives in the entity that owns the field. `ManageInfrastructure` refuses an unaffordable
  command, so the floor is unreachable through it — and that is the point: the clamp
  documents that a balance is never negative regardless of caller.
  """
  @spec debit(t(), float()) :: t()
  def debit(map, amount) do
    %{map | money: max(0.0, map.money - amount)}
  end
```

- [ ] **Step 4: Add the gates**

Replace `place/4` and `demolish/3` in `lib/armchair_metropolist/use_cases/manage_infrastructure.ex`:

```elixir
  @doc """
  Place a new node of `type` at `(x, y)` on `city_map`.

  Validates, in order: the coordinates are in bounds, the type is a known node type, the
  cell is not already occupied, and the treasury covers the type's construction cost.

  **Two of those orderings are load-bearing.** `unknown_type` must stay above the cost
  check because `Node.construction_cost/1` is a `Map.fetch!` — an unknown type reaching it
  raises `KeyError` inside a `GenServer.call` instead of returning an error tuple, which
  takes the engine down and rolls the city back to its last checkpoint. And
  `insufficient_funds` goes last, so a click on an occupied cell reports occupancy rather
  than reporting that you are broke about a build that was never possible there.
  """
  @spec place(CityMap.t(), integer(), integer(), atom()) ::
          {:ok, {CityMap.t(), Node.t()}}
          | {:error, :out_of_bounds | :occupied | :unknown_type | :insufficient_funds}
  def place(city_map, x, y, type) do
    cond do
      not CityMap.in_bounds?(city_map, x, y) ->
        {:error, :out_of_bounds}

      type not in Node.types() ->
        {:error, :unknown_type}

      CityMap.occupied?(city_map, x, y) ->
        {:error, :occupied}

      city_map.money < Node.construction_cost(type) ->
        {:error, :insufficient_funds}

      true ->
        node = Node.new(x, y, type)

        city_map =
          city_map
          |> CityMap.put_node(node)
          |> CityMap.debit(Node.construction_cost(type))

        {:ok, {city_map, node}}
    end
  end

  @doc """
  Remove the node at `(x, y)` from `city_map`, charging the flat demolition cost.

  Reports `:empty` before `:insufficient_funds`, for the same reason `place/4` reports
  occupancy first.
  """
  @spec demolish(CityMap.t(), integer(), integer()) ::
          {:ok, {CityMap.t(), String.t()}} | {:error, :empty | :insufficient_funds}
  def demolish(city_map, x, y) do
    cond do
      is_nil(CityMap.get_node(city_map, x, y)) ->
        {:error, :empty}

      city_map.money < Node.demolition_cost() ->
        {:error, :insufficient_funds}

      true ->
        node = CityMap.get_node(city_map, x, y)

        city_map =
          city_map
          |> CityMap.delete_node(x, y)
          |> CityMap.debit(Node.demolition_cost())

        {:ok, {city_map, node.id}}
    end
  end
```

The comparison is exact — `<`, no epsilon. There is no rounding downstream of it, and a tolerance would permit a build that drives the balance below zero.

- [ ] **Step 4b: Widen `CityEngine`'s two `@spec`s**

In `lib/armchair_metropolist/infrastructure/simulation/city_engine.ex`, `place/4` declares `{:error, :out_of_bounds | :occupied | :unknown_type}` and `demolish/3` its own union. Both now pass `:insufficient_funds` through from the use case, and Task 4 matches it in the LiveView. Add the member to both.

No behaviour changes and nothing fails if you skip it — the `check` alias runs no dialyzer. That is precisely why it is a numbered step: an un-checked `@spec` that lies about a public API's error union is how the next reader learns the wrong contract.

- [ ] **Step 4c: The two engine-level tests the spec asks for**

Spec §9 names these and this plan's first draft dropped both. They go in `city_engine_test.exs`, which seeds its snapshot per-test *before* `start_supervised!`, so a balance is easy to set here:

The affordable half must come **first** and pay for itself, so that one engine on one seeded balance exercises both directions. A 0.0 seed cannot do it — there would be no affordable command to compare against.

```elixir
    test "a refused command broadcasts nothing, but an accepted one does" do
      StubSnapshotRepository.set_initial({:ok, {0, %{CityMap.new(40, 30) | money: 20.0}}})
      start_supervised!({CityEngine, city_id: "refusal"})
      Phoenix.PubSub.subscribe(ArmchairMetropolist.PubSub, CityEngine.topic("refusal"))

      # Affordable: exactly 20 for a park, leaving zero. Broadcast expected.
      assert {:ok, _node} = CityEngine.place("refusal", 1, 1, :park)
      assert_receive {:city_metrics, _}

      # Now broke. Refused, and silent.
      assert {:error, :insufficient_funds} = CityEngine.place("refusal", 2, 2, :park)
      refute_receive {:city_metrics, _}, 50
    end

    test "metrics broadcast after a place carry the post-debit balance" do
      # The treasury line must move on the click, not on the next tick. Nothing else
      # catches an engine that computes metrics before debiting.
      StubSnapshotRepository.set_initial({:ok, {0, %{CityMap.new(40, 30) | money: 100.0}}})
      start_supervised!({CityEngine, city_id: "debited"})
      Phoenix.PubSub.subscribe(ArmchairMetropolist.PubSub, CityEngine.topic("debited"))

      {:ok, _node} = CityEngine.place("debited", 1, 1, :park)

      assert_receive {:city_metrics, metrics}
      assert metrics.money == 80.0
    end
```

Check `city_engine_test.exs`'s existing conventions for subscribing and for the city id it uses — follow them rather than the literal strings above if they differ. If the engine turns out to compute metrics *before* the debit, that is a real defect in Task 3's wiring: fix the order, do not weaken the assertion to 100.0.

- [ ] **Step 5: Add a property test**

In `test/armchair_metropolist/use_cases/manage_infrastructure_test.exs`. Check the file's existing imports; if it does not already `use ExUnitProperties`, add it alongside `use ExUnit.Case`:

```elixir
    property "place/4 either succeeds and debits exactly the cost, or fails and changes nothing" do
      check all type <- StreamData.member_of(Node.types()),
                money <- StreamData.float(min: 0.0, max: 200.0) do
        map = %{CityMap.new(40, 30) | money: money}
        cost = Node.construction_cost(type)

        case ManageInfrastructure.place(map, 1, 1, type) do
          {:ok, {placed, _node}} ->
            assert placed.money == money - cost
            assert map_size(placed.nodes) == 1

          {:error, :insufficient_funds} ->
            assert money < cost
        end
      end
    end
```

This is the invariant the individual cases sample: never a partial outcome, and a refusal only when genuinely short.

- [ ] **Step 6: Run the tests, then the full suite**

```bash
mix test test/armchair_metropolist/domain/entities/city_map_test.exs test/armchair_metropolist/use_cases/manage_infrastructure_test.exs test/armchair_metropolist/domain/services/simulation_calculator_test.exs
mix test
```

Expected: the targeted files PASS. **The full suite will have failures, and this step's real work is fixing them.** They are expected: several fixtures place nodes freely against what is now a 150 grant. Do not fix any of them by raising the grant.

Note that **none of these fixtures holds a `CityMap` it can edit** — they all drive a running engine. `%{map | money: 10_000.0}` is not available to them. The mechanism is to seed the *stored snapshot* before the engine starts, since `StubSnapshotRepository.load/1` is what the engine hydrates:

```elixir
StubSnapshotRepository.set_initial({:ok, {0, %{CityMap.new(40, 30) | money: 10_000.0}}})
```

Seeding an **empty** rich city and then placing through the engine preserves the semantics each fixture needs — in particular `starve/1`'s docstring is explicit that its consumers must be *placed* through a running engine rather than seeded into the snapshot, because a seeded deficit is by design already announced and cannot produce the edge the notification tests are about. Seeding money only, with no nodes, does not touch that.

The four sites, with what each needs:

1. **`city_engine_test.exs`, the `starve/1` helper (~line 980) and its five callers (~565, 577, 610, 637, 664).** `starve/1` places ten commercial at 40 each = 400. Each of those five tests already calls `set_initial` before `start_supervised!`; add `money: 10_000.0` to the city it seeds. Because the seeded city stays empty, `starve/1` still places every consumer through the running engine.
2. **`city_engine_test.exs` ~line 622** — same fix, same reason.
3. **`simulator_live_test.exs` ~287-290** — places two power plants (160 > 150) and asserts `data-count="2"`. This file starts its engine in a shared `setup`, so it needs the `treasury` tag mechanism that **Task 4 Step 1 introduces**. Two options, and the choice is yours to make and report: either land the tag mechanism here in Task 3 (it is six lines and Task 4 then just uses it), or tag these tests in Task 4 and leave them red across one commit. **Prefer the first** — a red suite between commits is worse than a slightly wider Task 3.
4. **`simulator_live_test.exs` ~340-347** — places three power plants (240) and asserts `"+360"`. Same fix. Do **not** change the placed type to something cheaper: the `+120`/`+360` figures are power production and would all have to move with it, which turns a fixture fix into a rebalance of the test's subject.

Report the exact failing list before and after. If a fixture fails for a reason not on this list, that is a finding — surface it rather than absorbing it.

- [ ] **Step 7: Mutation-verify**

1. `<` → `<=` in `place/4` → "a balance exactly equal to the cost succeeds and leaves zero" fails. Nothing else catches this. Restore.
2. Debit before the gate (move `CityMap.debit/2` above the `cond`) → "refuses an unaffordable build and changes nothing at all" fails on the money assertion. Restore.
3. Move the `insufficient_funds` clause above `occupied?` → "reports occupancy before affordability" fails. Restore.
4. Move it above the `type not in Node.types()` clause → "reports an unknown type before affordability, and does not raise" fails with `KeyError`, which is the crash that ordering prevents. Restore.

- [ ] **Step 8: Commit**

```bash
git add lib/armchair_metropolist/domain/entities/city_map.ex lib/armchair_metropolist/use_cases/manage_infrastructure.ex test/
git commit -m "feat(domain): building and demolishing spend from the treasury

place/4 gates on the type's construction cost and demolish/3 on the flat
demolition cost, both debiting on success. Two clause orderings are load-bearing
and each has a test: unknown_type above the cost lookup, because
construction_cost/1 is a Map.fetch! whose KeyError would crash the engine; and
insufficient_funds last, so an occupied cell reports occupancy.

The charge never enters demanded(:money) — it is a withdrawal from a stock, not a
per-tick flow, and folding it in would corrupt the legend's totals cell."
```

---

## Task 4: Refusal feedback

**Files:**
- Modify: `lib/armchair_metropolist_web/live/simulator_live.ex`
- Modify: `test/armchair_metropolist_web/live/simulator_live_test.exs`

**Interfaces:**
- Consumes: `{:error, :insufficient_funds}` from Task 3; `Node.construction_cost/1` and `Node.demolition_cost/0` from Task 1.
- Produces: an `:error` flash on a refused command; the treasury renders floored.

- [ ] **Step 1: Write the failing tests**

`Layouts.app` already renders `<.flash_group flash={@flash} />`, so `put_flash/3` needs no new plumbing. Add to `test/armchair_metropolist_web/live/simulator_live_test.exs`:

**First, the mechanism for setting a balance — read this before writing any test.**

`place/4` already exists in this file (~line 795) and already returns the rendered HTML. Do **not** add a second one: a non-adjacent duplicate clause trips "clauses with the same name and arity should be grouped together", and `mix check` compiles with `--warnings-as-errors`.

There is **no** `set_treasury/2` and there must not be one. The refusal is decided by `ManageInfrastructure` against the *engine's* `city_map.money`, so a helper that only broadcasts `{:city_metrics, …}` would change `socket.assigns.metrics` and nothing else — the click would still succeed against the engine's real balance and no flash would appear. Adding a test-only setter to `CityEngine` is also out.

The only mechanism that works is seeding the stored snapshot the engine hydrates, and this file starts its engine in the shared `setup`, before any test body runs. So parameterise the setup with an ExUnit tag (six lines; Task 3 Step 6 may already have landed this, in which case skip to the tests):

```elixir
    StubSnapshotRepository.set_initial(initial_snapshot(context))
    start_supervised!({CityEngine, city_id: CityEngine.default_city_id()})
```

with `setup %{conn: conn}` widened to `setup %{conn: conn} = context` and, beside the other helpers:

```elixir
  # `@tag treasury: n` seeds the balance of the city this test's engine hydrates.
  # There is no other way to set it: the engine owns the money, the refusal is decided
  # against the engine's copy, and this file starts its engine in `setup` — before any
  # test body could seed anything. Untagged tests get `{:error, :not_found}` exactly as
  # before, so the engine builds a fresh `CityMap` and they see the opening grant.
  #
  # The city is seeded *empty*: only the balance is preloaded, so every node in every
  # test is still placed through the running engine.
  defp initial_snapshot(%{treasury: money}) do
    {:ok, {0, %{CityMap.new(40, 30) | money: money}}}
  end

  defp initial_snapshot(_context), do: {:error, :not_found}
```

Now the tests:

```elixir
    @tag treasury: 79.6
    test "the treasury renders floored, not rounded", %{conn: conn} do
      # 79.6 rounding to 80 while an 80-cost build is refused is a cell contradicting
      # itself. Both halves asserted together, because the defect is precisely the two
      # disagreeing — and 79.6 is chosen so they *can* disagree: at a whole number
      # `trunc` and `round` return the same thing and the test could not fail.
      {:ok, view, _html} = live(conn, ~p"/")

      assert view |> element("#metrics-treasury") |> render() =~ "79"
      refute view |> element("#metrics-treasury") |> render() =~ "80"
    end

    @tag treasury: 39.6
    test "a refused build flashes the cost and the balance", %{conn: conn} do
      # 39.6 rather than 40.0 for the same reason as above: the flash floors the balance
      # too, and a whole-number fixture could not tell `trunc` from `round`.
      {:ok, view, _html} = live(conn, ~p"/")

      html = place(view, :power_plant, 1, 1)

      assert html =~ "Not enough money"
      assert html =~ "power_plant costs 80"
      assert html =~ "treasury holds 39"
    end

    test "an affordable build flashes nothing", %{conn: conn} do
      # The positive case. Without it, the assertions above pass against a page that
      # flashes on every click. No tag: the untouched 150 grant covers an 80 plant.
      {:ok, view, _html} = live(conn, ~p"/")

      refute place(view, :power_plant, 1, 1) =~ "Not enough money"
    end

    @tag treasury: 24.0
    test "a refused demolition flashes the demolition cost", %{conn: conn} do
      # Seeded at 24 and then spent down *by playing*: a park costs 20, leaving 4, which
      # is below the flat 10 demolition fee. No mid-test balance setter needed, and the
      # path is one a player can actually walk.
      {:ok, view, _html} = live(conn, ~p"/")
      place(view, :park, 2, 2)

      html =
        view
        |> element(~s{[phx-click="demolish"][phx-value-x="2"][phx-value-y="2"]})
        |> render_click()

      assert html =~ "demolishing costs 10"
      assert html =~ "treasury holds 4"
    end
```

Check the file's existing tests for whether they take `%{conn: conn}` from the context or rely on the setup's rebinding, and match that.

- [ ] **Step 2: Run them to verify they fail**

```bash
mix test test/armchair_metropolist_web/live/simulator_live_test.exs
```

Expected: the treasury test fails (`round/1` gives 80), and the three flash tests fail because the handlers discard the error.

- [ ] **Step 3: Floor the treasury**

```elixir
      <p id="metrics-treasury">Treasury: {trunc(@metrics.money)}</p>
```

Add a comment saying why, because the next reader will otherwise "tidy" it back to `round/1`:

```elixir
      <%!-- `trunc/1`, not `round/1`: this figure is spendable, and rounding it up makes
            the page contradict itself — a balance of 79.6 would read 80 while an 80-cost
            build is refused. Because every construction cost is a whole number,
            `trunc(money) >= cost` exactly when `money >= cost`, so the floored display
            and the domain's exact comparison agree. --%>
```

- [ ] **Step 4: Flash on refusal**

```elixir
  def handle_event("place", %{"x" => x, "y" => y}, socket) do
    x = String.to_integer(x)
    y = String.to_integer(y)
    type = socket.assigns.selected_type

    case CityEngine.place(socket.assigns.city_id, x, y, type) do
      {:ok, node} ->
        {:noreply, stream_insert(socket, :nodes, node)}

      {:error, :insufficient_funds} ->
        {:noreply, put_flash(socket, :error, unaffordable(type, socket.assigns.metrics.money))}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  def handle_event("demolish", %{"x" => x, "y" => y}, socket) do
    x = String.to_integer(x)
    y = String.to_integer(y)

    case CityEngine.demolish(socket.assigns.city_id, x, y) do
      {:ok, id} ->
        {:noreply, stream_delete_by_dom_id(socket, :nodes, id)}

      {:error, :insufficient_funds} ->
        {:noreply,
         put_flash(socket, :error, unaffordable_demolition(socket.assigns.metrics.money))}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end
```

and the two message builders:

```elixir
  # Both figures named, not just the refusal: the gap is what tells a player how long to
  # wait. `trunc/1` matches the treasury line's own flooring — a message saying the
  # treasury holds 80 while an 80-cost build was refused would be the same
  # self-contradiction in another place.
  #
  # The other three placement errors stay silent. `:out_of_bounds` is unreachable from a
  # grid that renders only in-bounds cells, and `:occupied` is nearly so, since the node
  # div sits above its cell and turns that click into a demolish.
  defp unaffordable(type, money) do
    "Not enough money: #{type} costs #{trunc(Node.construction_cost(type))}, " <>
      "treasury holds #{trunc(money)}."
  end

  defp unaffordable_demolition(money) do
    "Not enough money: demolishing costs #{trunc(Node.demolition_cost())}, " <>
      "treasury holds #{trunc(money)}."
  end
```

- [ ] **Step 5: Run the tests, then the suite**

```bash
mix test test/armchair_metropolist_web/live/simulator_live_test.exs
mix test
```

Expected: PASS, no failures.

- [ ] **Step 6: Mutation-verify**

1. `trunc/1` → `round/1` on the treasury line → "the treasury renders floored, not rounded" fails. Restore.
2. `trunc/1` → `round/1` in `unaffordable/2` → "a refused build flashes the cost and the balance" fails, because 39.6 rounds to 40 and truncs to 39. Confirm this actually reddens: if it does not, the fixture has been changed to a whole number somewhere and the assertion can no longer fail. That is the whole reason the tag is 39.6 and not 40.0.
3. Drop the `{:error, :insufficient_funds}` clause (let it fall through to the silent one) → all three flash tests fail. Restore.

- [ ] **Step 7: Commit**

```bash
git add lib/armchair_metropolist_web/live/simulator_live.ex test/armchair_metropolist_web/live/simulator_live_test.exs
git commit -m "feat(web): explain a refused build instead of ignoring the click

A refused place or demolish now flashes both figures — what it costs and what the
treasury holds — so the gap tells the player how long to wait. The other
placement errors stay silent; they are unreachable from the grid.

The treasury renders floored rather than rounded. Rounding made the page
contradict itself: 79.6 read as 80 while an 80-cost build was refused."
```

---

## Task 5: The cost column and affordability

**Files:**
- Modify: `lib/armchair_metropolist_web/live/simulator_live.ex`
- Modify: `test/armchair_metropolist_web/live/simulator_live_test.exs`

**Interfaces:**
- Consumes: `Node.construction_cost/1` (Task 1); `@metrics.money`.
- Produces: `[data-cell="<type>-cost"]` in every legend row, and `data-affordable` on the row.

- [ ] **Step 1: Write the failing tests**

```elixir
    test "every legend row shows its construction cost", %{conn: conn} do
      # Asserted on the cell's *text*, not on `render/1`'s HTML. The HTML includes the
      # `title` attribute added in this same step, whose value is "costs 80" — so
      # `render() =~ "80"` would pass even if the cell body rendered the count, or the
      # demolition cost, or nothing at all. An exact match on trimmed text can fail.
      {:ok, view, _html} = live(conn, ~p"/")

      assert cost_text(view, :power_plant) == "80"
      assert cost_text(view, :residential) == "15"
    end

    test "the cost column survives a collapse, unlike the resource columns", %{conn: conn} do
      # The type rows are the only way to choose what to place, and choosing now spends
      # money — so price cannot be detail-only.
      {:ok, view, _html} = live(conn, ~p"/")
      view |> element("#toggle-legend-detail") |> render_click()

      assert has_element?(view, ~s{[data-cell="power_plant-cost"]})
      refute has_element?(view, ~s{[data-cell="power_plant-power"]})
    end

    @tag treasury: 40.0
    test "unaffordable rows are marked, affordable ones are not", %{conn: conn} do
      # Both directions: a hardcoded "false" would satisfy either alone. 40 sits between
      # residential's 15 and power_plant's 80, so one row must be marked each way.
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, ~s{#legend-row-power_plant[data-affordable="false"]})
      assert has_element?(view, ~s{#legend-row-residential[data-affordable="true"]})
    end
```

with the text helper:

```elixir
  defp cost_text(view, type) do
    view
    |> element(~s{[data-cell="#{type}-cost"]})
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.text()
    |> String.trim()
  end
```

`Floki` is already a dependency — `Phoenix.LiveViewTest` requires it. If an existing helper in this file already extracts cell text, use that instead of adding a second one.

- [ ] **Step 2: Run them to verify they fail**

Expected: all three fail — no cost cell and no `data-affordable` attribute exist.

- [ ] **Step 3: Add the column**

In the legend's `<thead>`, after the `#` header:

```heex
              <th class="text-right">cost</th>
```

**Not** `:if={@detail}` — see the test's comment above.

**Then fix the totals row's `colspan`, or every total lands under the wrong resource.** `<tfoot>`'s label cell is currently

```heex
              <th class="text-left" colspan="2">supplied/demanded · met this tick</th>
```

spanning the type and count columns. A third always-visible column makes that `colspan="3"`. Miss it and the header and body carry nine columns while the footer carries eight, so money's total renders under `labour`, labour's under `traffic`, and the last resource gets none — **and no test catches it**, because `data-total={resource}` stays correct on each cell regardless of where the browser lays it out. The existing totals assertions all pass against the broken table. Verify this one by eye in the preview during Step 5, and add it to the mutation list below.

In the row, add the attribute and the dimming class:

```heex
            <tr
              :for={type <- @node_types}
              id={"legend-row-#{type}"}
              data-count={@metrics.by_type[type].count}
              data-affordable={to_string(affordable?(@metrics.money, type))}
              class={[
                type == @selected_type && "bg-primary/20",
                not affordable?(@metrics.money, type) && "opacity-40"
              ]}
            >
```

and the cell, after the count cell:

```heex
              <td
                data-cell={"#{type}-cost"}
                class="text-right tabular-nums"
                title={cost_title(@metrics.money, type)}
              >
                {trunc(Node.construction_cost(type))}
              </td>
```

with the helpers:

```elixir
  # Compared on the raw float, exactly as `ManageInfrastructure.place/4` does, so the
  # dimming and the refusal can never disagree about a type. The *displayed* treasury is
  # floored, and because every cost is a whole number `trunc(money) >= cost` exactly when
  # `money >= cost` — which is what keeps the greyed row and the printed balance
  # consistent.
  defp affordable?(money, type), do: money >= Node.construction_cost(type)

  # The row is dimmed, which is a visual-only signal; the title carries the same fact for
  # anyone who cannot see it. The select button stays enabled deliberately — choosing an
  # unaffordable type is harmless and is often what a player wants while waiting for
  # income.
  defp cost_title(money, type) do
    cost = trunc(Node.construction_cost(type))

    if affordable?(money, type),
      do: "costs #{cost}",
      else: "costs #{cost} — more than the treasury holds"
  end
```

- [ ] **Step 4: Run the tests, then the suite**

Expected: PASS, no failures.

- [ ] **Step 5: Re-measure both wrap thresholds**

An always-visible column widens **both** matrices, so both constants in `render/1` move — currently `max-[2010px]` expanded and `max-[1275px]` collapsed. The money design's two resource columns moved only the expanded one, because the collapsed table has no resource columns; a cost column is in both.

Follow the procedure recorded in `render/1`'s own comment, in each collapse state: force `flexDirection` on the real inner div and binary-search the real viewport for where the sidebar stops wrapping, giving `W_col` and `W_row`; confirm at the boundary pixel; set each constant to its window's **midpoint**.

Use the Browser-pane preview tools (`preview_start` with the dev server from `.claude/launch.json`, then `resize_window` / `javascript_tool`), never `mix phx.server` via Bash. **Do not compute the new values from the old ones plus an estimated column width** — that comment records the arithmetic being wrong every time it was tried, because a `width: 100%` table reports its container rather than its content.

Record both measured windows and both chosen midpoints in the comment, replacing the stale figures. If the browser tooling is unavailable to you, say so explicitly and report DONE_WITH_CONCERNS rather than guessing or leaving the old constants in place.

- [ ] **Step 6: Mutation-verify**

1. Make the cost cell `:if={@detail}` → "the cost column survives a collapse" fails. Restore.
2. Invert `affordable?/2` → both directions of the affordability test fail. Restore.
3. Render `{@metrics.by_type[type].count}` in the cost cell instead of the cost → "every legend row shows its construction cost" fails. This is the mutation the `Floki.text` assertion exists for; against `render() =~ "80"` it would have stayed green, because the `title` attribute carries the figure. Restore.
4. Revert the `colspan` to `2` → **no test fails**. Confirm that, then look at the expanded legend in the preview and confirm the totals are visibly one column out. Record it in your report: this is a defect the suite cannot see, and the next person to touch the column count needs to know that.

- [ ] **Step 7: Commit**

```bash
git add lib/armchair_metropolist_web/live/simulator_live.ex test/armchair_metropolist_web/live/simulator_live_test.exs
git commit -m "feat(web): show what each block costs, and dim what you cannot afford

The cost column is always visible, unlike the resource columns: the type rows are
the only way to choose what to place, and choosing now spends money.
Affordability is compared on the raw float, exactly as the domain does, so the
dimmed row and the refused click can never disagree.

Both wrap thresholds re-measured, since an always-visible column widens the
collapsed matrix as well as the expanded one."
```

---

## Task 6: Document the prices

**Files:**
- Modify: `test/support/playing_guide.ex`
- Modify: `docs/PLAYING.md`

**Interfaces:**
- Consumes: everything above.
- Produces: nothing. This is the last task.

- [ ] **Step 1: Add the `costs` block to the generator**

In `test/support/playing_guide.ex`, add `"costs" => costs_block()` to `blocks/0` and:

```elixir
  defp costs_block do
    rows = for type <- sorted_types(), do: "| `#{type}` | #{num(Node.construction_cost(type))} |"

    Enum.join(
      ["| type | cost to build |", "|---|---|"] ++
        rows ++
        [
          "",
          "Demolishing anything costs #{num(Node.demolition_cost())}, whatever it was. " <>
            "A new city starts with #{num(CityMap.opening_grant())}."
        ],
      "\n"
    )
  end
```

`CityMap` is already aliased in that module. Every figure is read from the domain, so a balance patch moves the guide.

- [ ] **Step 2: Add the marker to the document**

`playing_guide_test.exs` asserts that every block's marker exists, so the markers must go in by hand before regenerating. In `docs/PLAYING.md`, in the Reference section after "What each type consumes", add:

```markdown
### What each type costs

<!-- generated:costs -->
<!-- /generated:costs -->
```

- [ ] **Step 3: Regenerate and check**

```bash
REGENERATE_PLAYING_GUIDE=1 mix test test/docs/playing_guide_test.exs
git --no-pager diff --no-ext-diff docs/PLAYING.md
```

`--no-ext-diff` matters: this repo configures difftastic and plain `git diff` is not a unified diff.

Expected: the block fills with seven rows plus the demolition and grant sentence reading `costs 10` and `starts with 150`. `sorted_types()` is **alphabetical**, so the rows read

```
commercial 40, industrial 60, park 20, power_plant 80, residential 15, transit_hub 40, water_plant 70
```

— *not* descending by price. Do not "fix" the generator to produce a descending list; the alphabetical order is the existing convention every other generated block follows. If any figure shows a decimal point, a cost is not a whole number and Task 1's guard failed.

- [ ] **Step 4: Rewrite the six affected prose passages**

All outside the `<!-- generated:… -->` markers.

**Read this first: only the fenced ` ```markdown ` blocks are content for the guide.** The `>` blockquotes after them are notes to you explaining what the earlier draft got wrong and why the replacement reads as it does. Do not copy a blockquote into `docs/PLAYING.md`.

**Every factual claim below has been checked against the merged code or measured.** Two false sentences reached this guide on the park-amenity branch by being plausible and unverified, so if you find yourself wanting to improve any sentence here, verify the replacement the same way — `mix run --no-start` against the domain — and report what you measured.

**(a) "The controls"** — placing can now be refused, and both gestures spend. Add after the three bullets:

```markdown
Both of those last two spend money. Placing charges the block's price and is refused
outright if the treasury will not cover it — the legend dims the rows you cannot afford,
and a refused click says what it wanted and what you have. Demolishing charges a flat
fee, which is less than the cheapest block but is not nothing: a city with an empty
treasury cannot tear anything down either.
```

**(b) "Build a house first"** — it gains a second, independent reason. Append:

```markdown
Money gives the same advice for a different reason. `residential` is the cheapest block at
15, it earns without consuming any money, and — alone on the empty grid — it is the only
block that stays healthy indefinitely, because it supplies its own workers. `commercial`
earns twelve times as much per tick, but placed by itself it has no workforce and decays
while it earns, so its income stops. Spend the whole grant on things that cannot earn and
the city has no way back — see "Running out of money" below.
```

> Do not shorten this to "the only one that earns money while spending none": `residential`
> and `commercial` **both** produce money and consume none, so that claim is false about
> which is unique. What distinguishes `residential` is that it survives alone. Measured: one
> residential is stable at health 100 over 400 ticks at +1/tick; one commercial earns 265
> over 200 ticks *while dying* of labour starvation.

**(c) The park paragraph** — it now costs 20. Add at the end of the first paragraph:

```markdown
At 20 it is the second-cheapest block, but it is not the cheapest workforce: a park adds 5
workers and consumes 1, so 20 buys 4 — while a house adds 5 and consumes none for 15. Parks
win on the resources they also fix, not on labour per coin. And the multiplier is capped at
one park per house, so a park beyond that ratio costs 20 to *lose* you a worker.
```

> The draft sentence here read "at 20 to build it is also the cheapest way to add
> workforce, which is why the smallest city with a park in it is three blocks rather than a
> support set." Both halves were wrong. Cost per net worker is **5.0** for a park (20 ÷ 4)
> against **3.0** for a house (15 ÷ 5), so the park is the *dearer* way to add workforce.
> And the three-block city's shape has nothing to do with prices — the paragraph three lines
> below already gives the real reason, which predates construction costs entirely: the park
> needs a house to staff it and a commercial block to cover its upkeep. Do not add a second,
> contradicting explanation next to it.

**(d) The rescue section** — bulldozing now has a price. Append to approach 1:

```markdown
That has a price now. Cutting a nineteen-block city back to the two houses the baseline
supports means seventeen demolitions, which is 170 — and a city whose money producers are
all dead earns nothing to pay it with. Start bulldozing while the treasury still has
something in it.
```

> 170, not 190: approach 1 keeps two residential standing, so it demolishes seventeen
> blocks and not nineteen. Read the approach before pricing it.

**(e) A new subsection, after the rescue section:**

```markdown
## Running out of money

The treasury is the one resource whose surplus survives a tick, and the one you can spend
to zero with no warning. Two things follow.

**A city with no income and no savings cannot act at all.** Money has no free baseline —
the only sources are `residential` and `commercial`, and production is scaled by health, so
a city whose housing and shops are all dead earns exactly nothing, forever. While the
treasury still holds 10 you can keep demolishing, which is the way out described above.
Once it reaches zero with nothing earning, every gesture is refused: you cannot build,
and you cannot tear down to make room. That is the one unrecoverable state in the game,
and it takes both halves — no income *and* no savings.

**Getting out is easier the earlier you start.** A house costs 15, needs no support on an
empty grid, and consumes no money, so on a clear grid one house is enough to start earning
again. On a crowded one it is not: the dead blocks around it still draw power, water, waste
and traffic, and a single house cannot satisfy that demand, so it decays too. Demolish
first, then rebuild — and keep enough in the treasury to do both.
```

> Two claims in the draft of this section were false and are corrected above. "At that point
> neither building nor demolishing is affordable and there is no way back" — false while the
> treasury still holds 10, which is exactly the situation the rescue section's approach 1
> addresses; the guide would have contradicted itself two sections apart. And "any treasury
> that can afford one can always climb back" — measured false: a fresh house added to
> nineteen dead blocks is itself at health 0 after 300 ticks. The unrecoverable state needs
> the conjunction, and the rescue needs an *empty enough* grid.

**(f) "The controls", the collapse sentence** — currently "**Show detail / Hide detail** collapses the legend to its type and count columns". Task 5 makes that false: cost is always visible. Change to "collapses the legend to its type, count and cost columns" (or whatever the column set actually is after Task 5 — check the rendered page, do not assume).

**(g) The "only way out" sentence near the top** — currently "Demolishing … is the only way out of a collapse." Spec §6 names this as one of two passages that become *outright false* and must be **rewritten, not amended**: demolishing is now itself something a broke city cannot afford. Replace with a sentence that says demolishing is the way out of a collapse *and costs money*, pointing at "Running out of money". Do not simply insert (a)'s new paragraph above it and leave it standing — the sentence is wrong on its own terms, and a reader who stops at it is misinformed.

- [ ] **Step 5: Verify and run the gate**

```bash
mix test test/docs/playing_guide_test.exs
mix check
```

Expected: guide test PASS (prose edits sit outside the markers — a failure means one landed inside), `mix check` exit 0. If coverage dropped below the 90% gate, the likely gap is an unexercised branch in `place/4` or `demolish/3`; check Task 3's tests survived.

- [ ] **Step 6: Commit**

```bash
git add test/support/playing_guide.ex docs/PLAYING.md
git commit -m "docs: document what building and demolishing cost

A generated costs block, read from the domain so a balance patch moves the guide,
plus the demolition fee and the opening grant.

Adds a 'Running out of money' section naming the one unrecoverable state
plainly, and naming both halves of it: money has no free baseline, so a city
whose housing and shops are all dead earns nothing — but it can still demolish
while the treasury holds 10. Only no income and no savings together are
terminal."
```

---

## Self-Review

**Spec coverage.** §2 the prices → Task 1. §3 where the charge lives, including both load-bearing clause orderings → Task 3. §5's floored treasury → Task 4; its cost column, dimming and re-measured thresholds → Task 5. §6 documentation → Task 6, all seven passages it names. §7's balance → verified against merged code before this plan was written; no task changes it. §8's accepted consequences → recorded in the spec and surfaced to the player by Task 6(e), which is the mitigation the spec asks for. §9's two engine-level tests — a refused command broadcasting nothing, and post-debit metrics — → Task 3 Step 4c. (The first draft of this plan dropped both while claiming §9 was covered.)

**This plan was reviewed before execution** by an independent Opus 5 pass, which returned sixteen confirmed findings; all sixteen are folded in above. Four would have stopped an executor mid-task, four would have put measured-false sentences into the player guide, and two were assertions that could not fail. The findings worth carrying forward as warnings:

- The suite **cannot see** the totals-row `colspan` defect (Task 5). Column-count changes here need an eye on the page, not a green suite.
- `render() =~ "<figure>"` on an element whose `title` repeats that figure is not a test (Task 5).
- A grep for a constant does not find its **derived** readers — `502.0` was the grant plus two ticks of income (Task 2).
- Fixtures that drive a running engine cannot be handed money directly; the balance is seeded into the stored snapshot before the engine starts (Tasks 3, 4).

**The grant is its own task** (Task 2) rather than folded into Task 3, because it changes a persisted default and breaks a different set of tests. Splitting keeps each reviewable, and Task 3 does not depend on the grant's *value*.

**Deliberately not built:** the "reset city" control, decided deferred. §8's dead end therefore ships, mitigated by documentation only (Task 6(e)). If a reviewer flags the dead end as a defect, that is the standing decision, not an oversight.

**Type consistency.** `Node.construction_cost/1` takes a `node_type()` and raises on anything else — relied on by Task 3's clause ordering and never called before the type is validated. `CityMap.debit/2` takes and returns a `CityMap.t()`. `place/4`'s error union gains exactly one member, `:insufficient_funds`, which Task 4 matches by name in both handlers. `CityMap.opening_grant/0` is the only way anything reads the grant after Task 2.

**Known ordering hazard for the executor.** Task 3 will break **four sites** — `starve/1` and its five callers plus one more test in `city_engine_test.exs`, and two multi-power-plant fixtures in `simulator_live_test.exs` — because they place nodes freely against what is now a 150 grant. That is expected; Task 3 Step 6 names each site, says what it needs, and explains why "give those fixtures money" is *not* available as written (none of them holds an editable `CityMap`). Do not raise the grant. A plan that did not say so would look like Task 3 had broken the suite.

**One cross-task dependency runs backwards.** Task 3's fix for the two `simulator_live_test.exs` fixtures needs the `treasury` tag that Task 4 Step 1 introduces. Task 3 Step 6 tells the executor to land those six lines early rather than leave the suite red across a commit. If tasks are dispatched to separate agents, the Task 3 agent must be told this; it is the one place where a later task's mechanism is needed earlier.
