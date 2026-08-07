# Waste as an accumulating stock Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make unprocessed waste a stock that adds to the next tick's load and drains at `capacity − emissions`, so outrunning your disposal capacity leaves a landfill behind.

**Architecture:** `carried(:waste)` returns the stock **negated**, which turns `resource_stats/1`'s existing `available = supplied + carried` into `supplied − stock` and its existing `deficit` into exactly the next tick's stock. No new formula is written. The persisted `CityMap` gains one field, and the migration for it lands **first**, before anything reads it.

**Tech Stack:** Elixir, Phoenix LiveView 1.2, ExUnit.

**Spec:** `docs/superpowers/specs/2026-08-07-waste-as-accumulating-stock-design.md`

## Global Constraints

- **No table value changes.** `@capacity_table`, `@load_table` and `@construction_cost_table` in `Node` keep every number. `@decay_per_tick 6.0`, `@regen_per_tick 1.0`, `@baseline_capacity` and `@opening_grant 400.0` are all unchanged.
- **Satisfaction is deliberately NOT floored at zero.** `satisfaction(supplied, demanded)` keeps its `min(1.0, ...)` and gains no `max(0.0, ...)`. A large backlog is *meant* to decay health faster than `@decay_per_tick`. If a task seems to need a floor, stop and report BLOCKED.
- **`flow_satisfaction` must keep reading `supplied` alone**, never `available`. It answers "is my per-tick economy balanced", which stays true while digging out of a backlog.
- **Only `waste` accumulates.** `traffic` stays a per-tick flow. `@carryover` becomes `[:money, :waste]` and nothing else.
- **`docs/PLAYING.md`'s generated blocks must regenerate byte-identical.** Every configuration they describe is deficit-free, so a moved figure there means the mechanic leaked somewhere it should not have. Task 4 verifies this.
- **Never restore an experimental mutation with `git checkout`** — it has destroyed uncommitted work on this project. Back the file up with `cp` first, or undo with a targeted edit.
- Run `mix test` before every commit. A pre-commit hook runs `mix precommit`; do not bypass it with `--no-verify`.
- `git diff` here uses difftastic and emits no `+`/`-` prefixes. Use `git diff --no-ext-diff` for a conventional diff.

---

### Task 1: Persist the field safely, before anything reads it

**Files:**
- Modify: `lib/armchair_metropolist/domain/entities/city_map.ex` — `@type t` and `defstruct`
- Modify: `lib/armchair_metropolist/infrastructure/persistence/snapshot_vocabulary.ex` — `modernize/1`
- Test: `test/armchair_metropolist/infrastructure/persistence/snapshot_vocabulary_test.exs`

**Interfaces:**
- Consumes: nothing.
- Produces: `%CityMap{waste_stock: float()}`, defaulting to `0.0`. Tasks 2 and 3 read and write it.

**Why this task is first and alone.** `CityMap` is persisted via `:erlang.term_to_binary/2` and decoded with `:safe`. A payload written before this field decodes to a struct with **no `:waste_stock` key**, so `city_map.waste_stock` raises `KeyError` — a crash-loop on every stored city. This project has had a production 500 from exactly that. Landing the field and its migration together, before any code reads it, means a half-shipped branch cannot break hydration.

- [ ] **Step 1: Write the failing tests**

Add to `test/armchair_metropolist/infrastructure/persistence/snapshot_vocabulary_test.exs`:

```elixir
  test "modernize/1 supplies waste_stock for a payload written before the field existed" do
    SnapshotVocabulary.ensure_loaded!()

    decoded =
      @pre_rename_fixture
      |> File.read!()
      |> :erlang.binary_to_term([:safe])

    # Asserted first, and load-bearing: it proves the fixture really is a
    # missing-key payload. Without it this test would silently become a no-op the
    # day someone regenerates the fixture against the current struct.
    refute Map.has_key?(decoded, :waste_stock),
           "the fixture must predate waste_stock for this test to mean anything"

    assert SnapshotVocabulary.modernize(decoded).waste_stock == 0.0
  end

  test "modernize/1 does not reset a waste_stock the city already carries" do
    # The mutation this exists to catch is `Map.put` where `Map.put_new` belongs.
    # It passes the test above, and silently wipes a real backlog on every hydrate
    # — a save-corrupting bug that no other test in the suite can see.
    city = %{CityMap.new(40, 30) | waste_stock: 42.0}

    assert SnapshotVocabulary.modernize(city).waste_stock == 42.0
  end
```

If `CityMap` is not already aliased in that test file, add `alias ArmchairMetropolist.Domain.Entities.CityMap`.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
mix test test/armchair_metropolist/infrastructure/persistence/snapshot_vocabulary_test.exs
```

Expected: both fail. The first with `KeyError` on `:waste_stock` (the struct has no such field yet); the second with a `KeyError` from the `%{... | waste_stock: 42.0}` update syntax, which requires the key to exist.

- [ ] **Step 3: Add the field to `CityMap`**

In `lib/armchair_metropolist/domain/entities/city_map.ex`, extend the type:

```elixir
  @type t :: %__MODULE__{
          width: pos_integer(),
          height: pos_integer(),
          tick: non_neg_integer(),
          nodes: %{optional(String.t()) => Node.t()},
          money: float(),
          waste_stock: float()
        }
```

and the struct:

```elixir
  defstruct width: 40,
            height: 30,
            tick: 0,
            nodes: %{},
            money: @opening_grant,
            waste_stock: 0.0
```

**Leave the persistence comment below `defstruct` as it is, and add this paragraph to it.** That comment currently warns only about *atoms* entering stored terms; a missing key is a different hazard and is not covered:

```elixir
  # A new field is also a hazard even when its values are plain floats: payloads
  # written before it exist decode without the key, so any `city_map.new_field`
  # raises `KeyError` on hydrate. `SnapshotVocabulary.modernize/1` supplies the
  # default for those, and the committed fixtures are what prove it — see
  # `waste_stock`, added 2026-08-07.
```

- [ ] **Step 4: Supply the default in `modernize/1`**

Replace `modernize/1` in `lib/armchair_metropolist/infrastructure/persistence/snapshot_vocabulary.ex`:

```elixir
  def modernize(%{nodes: nodes} = city_map) when is_map(nodes) do
    # `Map.put_new`, not the `%{map | key: value}` update syntax: that syntax
    # requires the key to already exist, which is exactly what an older payload
    # does not have. And not `Map.put` either — see the test that seeds a city
    # with a real backlog, which a `put` would silently reset to zero on every
    # hydrate.
    city_map
    |> Map.put_new(:waste_stock, 0.0)
    |> Map.put(:nodes, Map.new(nodes, fn {id, node} -> {id, rename_type(node)} end))
  end
```

Also extend the function's `@doc` — it currently says a city that skips this "carries retired atoms into the domain". Add that it also supplies defaults for fields added since the payload was written.

- [ ] **Step 5: Run the tests to verify they pass**

```bash
mix test test/armchair_metropolist/infrastructure/persistence/snapshot_vocabulary_test.exs
```

Expected: PASS.

- [ ] **Step 6: Run the full suite**

```bash
mix test
```

Expected: PASS. The field is inert — nothing reads it yet.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: add a persisted waste_stock field with its hydration default"
```

---

### Task 2: The stock mechanic

**Files:**
- Modify: `lib/armchair_metropolist/domain/services/simulation_calculator.ex` — `@carryover`, `carried/2`, `advance_tick/1`, moduledoc
- Test: `test/armchair_metropolist/domain/services/simulation_calculator_test.exs`

**Interfaces:**
- Consumes: `%CityMap{waste_stock: float()}` from Task 1.
- Produces: `advance_tick/1` returns a `CityMap` whose `waste_stock` is the previous tick's waste `deficit`. Task 3 surfaces it.

- [ ] **Step 1: Write the failing tests**

Add to `test/armchair_metropolist/domain/services/simulation_calculator_test.exs`. The file already has a `map_with/1` helper taking a list of nodes.

```elixir
**`five_houses/0` is a module-level private function — Elixir does not allow `defp` inside a `describe` block.** Put it at the bottom of the file beside `map_with/1` and the other helpers:

```elixir
  # Five houses emit 50 waste against the free baseline's 40. Five and not four:
  # four emit exactly 40, leave nothing, and would make every waste-stock
  # assertion read the same whether the mechanic exists or not.
  defp five_houses, do: map_with(for i <- 0..4, do: Node.new(i, 0, :residential))
```

Then the describe block itself:

```elixir
  describe "waste as an accumulating stock" do
    test "unprocessed waste carries into the next tick" do
      city = five_houses()
      assert city.waste_stock == 0.0

      {next, _delta} = Calc.advance_tick(city)

      # 50 emitted, 40 absorbed by the baseline, 10 left in the ground.
      assert_in_delta next.waste_stock, 10.0, 0.001
    end

    test "the stock drains on spare capacity and reaches exactly zero" do
      # Five houses (50 emitted) plus one industrial (90 capacity) against the
      # baseline's 40: capacity 130, emissions 50, so the stock falls by 80 a tick.
      nodes = [Node.new(9, 9, :industrial) | for(i <- 0..4, do: Node.new(i, 0, :residential))]
      city = %{map_with(nodes) | waste_stock: 200.0}

      {t1, _} = Calc.advance_tick(city)
      {t2, _} = Calc.advance_tick(t1)
      {t3, _} = Calc.advance_tick(t2)

      assert_in_delta t1.waste_stock, 120.0, 0.001
      assert_in_delta t2.waste_stock, 40.0, 0.001

      # Exactly zero, not merely smaller: a stock that decreases without ever
      # clearing is a different and much crueller mechanic.
      assert t3.waste_stock == 0.0
    end

    test "a backlog worsens satisfaction instead of improving it" do
      # THE mutation this whole describe block exists to catch: `carried(:waste)`
      # returning +stock rather than -stock turns the landfill into a second
      # treasury. Every "the city survives" test in the suite passes under it.
      clean = five_houses()
      backlogged = %{five_houses() | waste_stock: 60.0}

      clean_sat = Calc.resource_stats(clean).waste.satisfaction
      backlogged_sat = Calc.resource_stats(backlogged).waste.satisfaction

      # 40/50 = 0.8 clean; (40 - 60)/50 = -0.4 backlogged. Under the sign mutation
      # the backlogged figure becomes min(1.0, 100/50) = 1.0 and this fails.
      assert_in_delta clean_sat, 0.8, 0.001
      assert_in_delta backlogged_sat, -0.4, 0.001
      assert clean_sat > backlogged_sat
    end

    test "the backlog does not touch flow_satisfaction" do
      # `flow_satisfaction` answers "is my per-tick economy balanced", which stays
      # true while digging out. Catches the mutation that wires the stock into it.
      clean = Calc.resource_stats(five_houses()).waste.flow_satisfaction
      backlogged = Calc.resource_stats(%{five_houses() | waste_stock: 60.0}).waste.flow_satisfaction

      assert_in_delta clean, 0.8, 0.001
      assert_in_delta backlogged, 0.8, 0.001
    end

    test "traffic does not accumulate" do
      # Only waste is in @carryover. Six houses draw 36 traffic against the
      # baseline's 40 and 60 waste against the same 40, so waste builds a stock
      # in the very same tick that traffic does not.
      city = map_with(for i <- 0..5, do: Node.new(i, 0, :residential))
      {next, _} = Calc.advance_tick(city)

      assert_in_delta next.waste_stock, 20.0, 0.001
      refute Map.has_key?(next, :traffic_stock)
      assert Calc.resource_stats(next).traffic.carried == 0.0
    end

    test "a large backlog decays health faster than @decay_per_tick" do
      # The consequence of leaving satisfaction unfloored, asserted directly so
      # that adding a `max(0.0, ...)` later reddens something.
      #
      # Five houses at 200 stock: waste demanded 50, supplied 40, available -160,
      # satisfaction -3.2. Power is the next worst at 40/75 = 0.533, so waste is
      # the binding constraint. health_delta = -(1 - -3.2) * 6.0 = -25.2.
      city = %{five_houses() | waste_stock: 200.0}
      {next, _} = Calc.advance_tick(city)

      assert_in_delta next.nodes["0:0"].health, 74.8, 0.001

      # And the contrast, so the figure above cannot be satisfied by a coincidence:
      # the same city with no backlog loses only (1 - 0.533) * 6.0 = 2.8.
      {clean_next, _} = Calc.advance_tick(five_houses())
      assert_in_delta clean_next.nodes["0:0"].health, 97.2, 0.001
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
mix test test/armchair_metropolist/domain/services/simulation_calculator_test.exs
```

Expected: all six fail — `waste_stock` stays `0.0` because nothing writes it, and satisfaction ignores the seeded stock.

- [ ] **Step 3: Add `:waste` to the carryover list**

In `lib/armchair_metropolist/domain/services/simulation_calculator.ex`, replace the `@carryover` attribute and its comment:

```elixir
  # The resources whose unspent supply survives the tick boundary. Money is a
  # treasury: its surplus carries forward as an asset. Waste is the mirror — its
  # *deficit* carries forward as a liability, which is why `carried/2` negates it.
  # Traffic does not accumulate: a landfill persists, a jam clears.
  @carryover [:money, :waste]
```

- [ ] **Step 4: Negate the stock in `carried/2`**

Replace `carried/2`:

```elixir
  # Derived from @carryover rather than matching on :money directly, so the list
  # is the single place a reader looks to learn which resources are treasuries.
  #
  # Waste is returned **negated**, and that one sign is the whole mechanic. It
  # makes `available = supplied + carried` read `supplied - stock`, and therefore
  # makes `deficit = max(0.0, demanded - available)` equal `demanded - supplied +
  # stock` — exactly the next tick's stock, with no second formula to keep in step.
  defp carried(city_map, :money), do: city_map.money
  defp carried(city_map, :waste), do: -city_map.waste_stock
  defp carried(_city_map, _resource), do: 0.0
```

- [ ] **Step 5: Write the stock in `advance_tick/1`**

In `advance_tick/1`, beside the existing money line:

```elixir
    money = new_balance(Map.fetch!(stats, :money))

    # The stock *is* the deficit — see `carried/2`. Read from the same pre-tick
    # `stats` every node saw, so the landfill and the health decay it caused
    # cannot disagree about the same tick.
    waste_stock = Map.fetch!(stats, :waste).deficit

    {%{city_map | nodes: nodes, tick: city_map.tick + 1, money: money, waste_stock: waste_stock},
     delta}
```

- [ ] **Step 6: Update the moduledoc**

The numbered walkthrough at the top of the module describes each tick. Step 9 currently covers money's surplus only. Extend it, and add step 10:

```
    9. Money's surplus persists: the city map's `money` balance becomes
       `max(0.0, supplied + carried - demanded)`, a treasury rather than a
       per-tick flow.
   10. Waste's *deficit* persists, as the mirror of that: the `waste_stock`
       balance becomes the tick's waste `deficit`, so unprocessed waste adds to
       the next tick's load and drains at `capacity - emissions`. Because the
       stock enters through `carried/2` negated, a backlog drives `satisfaction`
       below zero and health decay past `@decay_per_tick` — which is therefore a
       coefficient, not a maximum.
```

Also amend step 3's description of `satisfaction`, which says it is `min(1.0, available / demand)` — still true, but note it is **not** floored at zero and why.

- [ ] **Step 7: Run the tests to verify they pass**

```bash
mix test test/armchair_metropolist/domain/services/simulation_calculator_test.exs
```

Expected: PASS.

- [ ] **Step 8: Run the full suite**

```bash
mix test
```

Expected: PASS. If any pre-existing test reddens, **do not adjust its expected value** — a changed assertion here means the mechanic reached a city that should have been deficit-free, which is a real finding. Report it.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "feat: carry unprocessed waste into the next tick as a stock"
```

---

### Task 3: Surface the landfill, and clamp the two negative displays

**Files:**
- Modify: `lib/armchair_metropolist/domain/entities/simulation_metrics.ex` — type, `defstruct`, `build/3`
- Modify: `lib/armchair_metropolist_web/live/simulator_live.ex` — metrics panel, `tightest_resource/1`
- Modify: `lib/armchair_metropolist/infrastructure/simulation/city_engine.ex` — `notify/1`
- Test: `test/armchair_metropolist/domain/entities/simulation_metrics_test.exs`, `test/armchair_metropolist_web/live/simulator_live_test.exs`, `test/armchair_metropolist/infrastructure/simulation/city_engine_test.exs`

**Interfaces:**
- Consumes: `%CityMap{waste_stock: float()}` from Task 1; the mechanic from Task 2.
- Produces: `%SimulationMetrics{waste_stock: float()}`, and a `#metrics-landfill` element.

- [ ] **Step 1: Write the failing tests**

In `test/armchair_metropolist/domain/entities/simulation_metrics_test.exs`:

```elixir
    test "carries the city's waste stock" do
      metrics = SimulationMetrics.build(%{CityMap.new(40, 30) | waste_stock: 78.0}, %{})

      assert metrics.waste_stock == 78.0
    end
```

In `test/armchair_metropolist_web/live/simulator_live_test.exs`, inside the metrics describe block:

```elixir
    test "the metrics panel shows the landfill, floored", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      send(view.pid, {:city_metrics, %{empty_city_metrics() | waste_stock: 78.6}})
      render(view)

      # `trunc`, matching the treasury line: 78.6 renders 78, never 79.
      assert view |> element("#metrics-landfill") |> render() =~ "78"
      refute view |> element("#metrics-landfill") |> render() =~ "79"

      # The label is a decision, so a rename should fail a test rather than pass.
      assert view |> element("#metrics-landfill") |> render() =~ "Landfill"
    end

    test "a negative satisfaction renders as 0%, not as a negative percentage",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      send(view.pid, {:city_metrics, metrics_with_waste_backlog()})
      render(view)

      tightest = view |> element("#metrics-tightest") |> render()

      # Positive case first: waste really is the tightest resource here, so this
      # is not a vacuous check on a line that never rendered.
      assert tightest =~ "waste"
      assert tightest =~ "0%"
      refute tightest =~ "-"
    end
```

and this fixture beside the others at the bottom of that file:

```elixir
  # Waste supplied 40 against demand 50 with a 60 backlog: available -20 and
  # satisfaction -0.4, which renders -40% unclamped. Built by hand rather than
  # via `stat/2`, which always sets `carried: 0.0` and so cannot produce a
  # negative satisfaction at all.
  defp metrics_with_waste_backlog do
    %{
      empty_city_metrics()
      | waste_stock: 60.0,
        resources: %{
          waste: %{
            supplied: 40.0,
            carried: -60.0,
            demanded: 50.0,
            deficit: 70.0,
            satisfaction: -0.4,
            flow_satisfaction: 0.8
          }
        }
    }
  end
```

In `test/armchair_metropolist/infrastructure/simulation/city_engine_test.exs`, in the deficit-notification describe block:

```elixir
    test "a waste backlog is reported at 0% rather than a negative percentage",
         %{city_id: city_id} do
      # Six houses emit 60 waste against the free baseline's 40, so a stock forms
      # on the first tick and drives satisfaction below zero on the second.
      seed_funded_city()
      start_supervised!({CityEngine, city_id: city_id})
      Enum.each(0..5, fn x -> {:ok, _node} = CityEngine.place(city_id, x, 0, :residential) end)

      broadcast_tick(1)
      assert_receive {:notified, _title, body}, 1_000

      assert body =~ "waste at 0% of demand"

      # The clamp is the point: unclamped this reads "waste at -50% of demand".
      # Asserted on the whole body rather than on the substring above, because a
      # negative figure for any other resource would be the same defect.
      refute body =~ "-"
    end
```

If the surrounding describe block does not already provide `city_id` and `broadcast_tick/1`, copy the setup from the neighbouring notification tests in that file rather than inventing one.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
mix test test/armchair_metropolist/domain/entities/simulation_metrics_test.exs test/armchair_metropolist_web/live/simulator_live_test.exs
```

Expected: `KeyError` on `:waste_stock` for the metrics test; no `#metrics-landfill` element; and the tightest line rendering `-40%`.

- [ ] **Step 3: Carry the stock on the metrics struct**

In `simulation_metrics.ex`, add `waste_stock: float()` to `@type t`, `waste_stock: 0.0` to `defstruct`, and to `build/3`'s returned struct, beside `money:`:

```elixir
      money: city_map.money,
      waste_stock: city_map.waste_stock,
```

- [ ] **Step 4: Add the Landfill line**

In `simulator_live.ex`'s `metrics/1`, directly after the treasury line:

```elixir
      <%!-- `trunc/1` for the same reason as the treasury above: this is a
            quantity the player reasons about against whole-number capacities,
            and rounding 78.6 up to 79 would overstate a backlog by a unit. --%>
      <p id="metrics-landfill">Landfill: {trunc(@metrics.waste_stock)}</p>
```

- [ ] **Step 5: Clamp the two display sites**

In `simulator_live.ex`'s `tightest_resource/1`:

```elixir
    # Clamped at the display layer only. A backlog drives `satisfaction` below
    # zero — see `carried/2` — and "waste -280%" is noise where "waste 0%" beside
    # the Landfill line is legible. The domain keeps the signed value because
    # `CityEngine`'s `sort_by` needs it to rank waste against other shortfalls.
    percent = max(0, round(stats.satisfaction * 100))
```

In `city_engine.ex`'s `notify/1`, the same clamp:

```elixir
        "#{resource} at #{max(0, round(stats.satisfaction * 100))}% of demand"
```

**Do not clamp `critical_resources/1`'s filter or its `sort_by`** — both want the signed value, and a clamp there would tie waste with any other fully-starved resource instead of ranking it first.

- [ ] **Step 6: Run the tests to verify they pass**

```bash
mix test
```

Expected: PASS, full suite.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: show the landfill and clamp negative satisfaction in display"
```

---

### Task 4: Re-measure the guide, and correct the comments the mechanic falsified

**Files:**
- Modify: `docs/PLAYING.md` — prose only; the generated blocks must not move
- Modify: `lib/armchair_metropolist/domain/services/simulation_calculator.ex` — `stalled?/2`'s comment

**Interfaces:**
- Consumes: the finished mechanic.
- Produces: nothing.

- [ ] **Step 1: Confirm the generated blocks did not move**

```bash
REGENERATE_PLAYING_GUIDE=1 mix test test/docs/playing_guide_test.exs
git --no-pager diff --no-ext-diff --stat docs/PLAYING.md
```

Expected: the regenerate reports the guide was already current and the diff is **empty**. Every configuration those blocks describe is deficit-free by construction, so a moved figure means the mechanic reached somewhere it should not have — stop and report BLOCKED rather than committing the new numbers.

- [ ] **Step 2: Reword `stalled?/2`'s comment**

Its comment currently ends the first paragraph with: *"and demand — which is not health-scaled — does not move. The next tick is therefore identical in every node."* The second sentence is now false of the city, whose stock moves, though still true of the nodes. Replace those two sentences with:

```
  # and demand — which is not health-scaled — does not fall. The next tick is
  # therefore identical in every *node*, which is what this predicate claims.
  # The city itself may still be changing: an unprocessed-waste stock keeps
  # growing underneath a stalled city, which only drives satisfaction further
  # below zero and so cannot rescue any node. Accumulation reinforces this
  # fixpoint rather than breaking it.
```

Leave both clauses of the function alone — the logic is unchanged.

- [ ] **Step 3: Re-measure the three at-risk prose claims**

The criterion from the spec: a documented scenario changes only if its health-weighted waste emissions exceed `40 + 90 × industrial + 8 × parks`. Per-type emissions are `commercial 14`, `power_plant 12`, `residential 10`, `water_plant 6`, `transit_hub 2`.

Measure each of these against the running engine — do not reason about them:

| `docs/PLAYING.md` | claim | why it is at risk |
|---|---|---|
| `:102` | the "residential, no support" table's "after 200 ticks" column | 10 waste per house; five houses cross the 40 baseline |
| `:273` | "node's health is still 0.0 after 150 ticks" | depends on the board's emitter count |
| `:292` | "within 100 ticks" | depends on the board's emitter count |

Measure with a script under the scratchpad directory, run via `mix run`. Read each claim's board out of the guide first — the counts below are placeholders for whatever that prose actually describes:

```elixir
# scratchpad/measure_waste_claims.exs
alias ArmchairMetropolist.Domain.Entities.{CityMap, Node}
alias ArmchairMetropolist.Domain.Services.SimulationCalculator, as: Calc

build = fn counts ->
  {city, _} =
    Enum.reduce(counts, {CityMap.new(40, 30), 0}, fn {type, n}, acc ->
      Enum.reduce(1..n//1, acc, fn _, {map, i} ->
        {CityMap.put_node(map, Node.new(rem(i, 40), div(i, 40), type)), i + 1}
      end)
    end)

  city
end

run = fn label, counts, ticks ->
  city = build.(counts)
  final = Enum.reduce(1..ticks, city, fn _, c -> elem(Calc.advance_tick(c), 0) end)
  healths = final |> CityMap.nodes() |> Enum.map(&round(&1.health)) |> Enum.frequencies()
  IO.puts("#{label}: after #{ticks} ticks  health=#{inspect(healths)}  landfill=#{round(final.waste_stock)}")
end

run.("residential-no-support", %{residential: 5}, 200)
run.("still-zero-after-150", %{residential: 5}, 150)
run.("recovers-within-100", %{residential: 2}, 100)
```

```bash
mix run /private/tmp/claude-501/-Users-adsouza-Code-armchair-metropolist/32dd0f6c-e24a-4abd-a73a-d067135e39b7/scratchpad/measure_waste_claims.exs
```

Update any figure that moved. In your report, list every claim you measured with its before and after value, including the ones that did not move — "unchanged" is a measurement, and a claim absent from the report is indistinguishable from one you skipped.

**These four are NOT at risk** — confirmed by the criterion, and listed so you do not re-measure them needlessly: `:54` ("offline in 14 ticks and dead in 17", 12 of 40, killed by labour), `:237` ("dies in 17 ticks", ≤ 14 of 40), `:174` (the opening pacing bound, never in deficit), `:408` ("two houses recover within 100 ticks", 20 of 40).

- [ ] **Step 4: Document the mechanic for players**

Add this paragraph to `docs/PLAYING.md` immediately after the free-baseline sentence in **"Why your first city dies"** (currently around `:92`, ending "...enough to absorb 40 waste and 40 traffic"):

```markdown
Waste is the one bad that keeps a score. Whatever you emit past your absorption
capacity stays in the ground as a **Landfill**, shown in the metrics panel, and it
is added to next tick's load — so a city that is 10 over runs 10 short, then 20,
then 30. The backlog drains at capacity minus emissions once you are back under,
which makes the exit from a waste spiral either an `industrial` block or fewer
emitters. Traffic does not work this way: a jam clears at the tick boundary, and
only waste accumulates.
```

Verify the figures in that paragraph against your Step 3 measurements before committing — "10 over runs 10 short, then 20, then 30" is the drain arithmetic from the spec's worked table and must match what the engine does.

Keep it to roughly this length. That section's prose participates in the page's wrap behaviour, and a much longer paragraph there is a layout change as well as a docs change.

- [ ] **Step 5: Run the full suite**

```bash
mix test
```

Expected: PASS, including `playing_guide_test.exs`.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "docs: document the landfill and re-measure the collapse figures"
```

---

## Final verification

- [ ] **The mechanic is real:** seed a city with a backlog, advance a tick, and confirm `waste_stock` fell by `capacity − emissions` and health fell by more than 6.0.
- [ ] **The migration holds:** `git diff main -- lib/armchair_metropolist/infrastructure/persistence/snapshot_vocabulary.ex` shows `Map.put_new`, not `Map.put`, for `:waste_stock`.
- [ ] **Nothing else accumulates:** `@carryover` is exactly `[:money, :waste]`.
- [ ] **Satisfaction is still unfloored:** `satisfaction/2` contains no `max(0.0, ...)`; the only clamps are the two display sites in Task 3.
- [ ] **The generated guide blocks are byte-identical to `main`:** `git diff main -- docs/PLAYING.md` shows prose changes only.
