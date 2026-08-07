# Negative resource polarity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `waste` and `traffic` read as bads that rise, so `industrial` reduces waste instead of producing it — without changing a single number in the simulation.

**Architecture:** The simulation is already the dual of the intended model: `industrial`'s `90.0` in the production table is *processing capacity*, a house's `10.0` in the consumption table is *emission*, and `min(1.0, capacity/load)` already decays health when the city outruns disposal. So this is a labelling and presentation change. `Node` gains the vocabulary (`@negative_resources`); the LiveView gains one `net/3` helper that owns the sign convention; the guide's generated tables gain the same sign. `SimulationCalculator` and `SimulationMetrics` are not touched.

**Tech Stack:** Elixir, Phoenix LiveView 1.2, ExUnit, LazyHTML (test-only HTML parsing — Floki is **not** available).

**Spec:** `docs/superpowers/specs/2026-08-07-negative-resource-polarity-design.md`

## Global Constraints

- **No table value changes.** `@production_table`, `@consumption_table` and `@construction_cost_table` in `lib/armchair_metropolist/domain/entities/node.ex` keep every number they have. Moving a number between the production and consumption tables would unscale removal from health and is the specific defect this design exists to avoid (spec §1).
- **No changes to `Domain.Services.SimulationCalculator` or `Domain.Entities.SimulationMetrics`.** If a task seems to need one, the design has been violated — stop and report.
- **Do not rename `Node.production/1` or `Node.consumption/1`.** That is a separate follow-up commit (spec §9), explicitly out of scope here.
- **Minus signs in code and tests are ASCII `-`.** `signed/1` builds its string with `to_string(rounded)` and `PlayingGuide.num/1` with `Integer.to_string/1`, both of which emit ASCII. The spec's prose uses U+2212 `−`; test assertions must not.
- **The two negative resources are `:waste` and `:traffic`**, in that order.
- **Run the full suite before every commit:** `mix test`. The project runs `mix precommit` via a git hook; do not bypass it.
- **Per-test rule:** no `refute` without the positive case asserted first, and a test you have not seen fail is not yet a test. Every task has an explicit "run it and watch it fail" step; do not skip it.

---

### Task 1: The polarity vocabulary in `Node`

**Files:**
- Modify: `lib/armchair_metropolist/domain/entities/node.ex` (add beside `@statuses` at :40, and beside `statuses/0` at :218)
- Test: `test/armchair_metropolist/domain/entities/node_test.exs` (add after the `resources/0` describe block, ~:50)

**Interfaces:**
- Consumes: nothing.
- Produces: `Node.negative_resources() :: [Node.resource()]` returning `[:waste, :traffic]`, and `Node.negative_resource?(Node.resource()) :: boolean()`. Tasks 2, 3 and 5 call `negative_resource?/1`.

- [ ] **Step 1: Write the failing tests**

Add to `test/armchair_metropolist/domain/entities/node_test.exs`, after the `describe "resources/0"` block:

```elixir
  describe "negative_resources/0" do
    test "names the two resources where a rising figure is bad" do
      assert Node.negative_resources() == [:waste, :traffic]
    end

    test "every negative resource is a resource" do
      # A typo'd atom would never match anything and would simply render the old
      # sign forever, with nothing else in the suite noticing.
      assert Enum.all?(Node.negative_resources(), &(&1 in Node.resources()))
    end
  end

  describe "negative_resource?/1" do
    test "is true for the bads and false for the goods" do
      # Both halves, in one test. A predicate hardcoded to `true` satisfies the
      # first loop alone; one hardcoded to `false` satisfies the second alone.
      # This is also the assertion that forces a polarity decision if a seventh
      # resource is ever added, rather than letting it default to positive.
      for resource <- [:waste, :traffic] do
        assert Node.negative_resource?(resource), "#{resource} must be negative"
      end

      for resource <- [:power, :water, :labour, :money] do
        refute Node.negative_resource?(resource), "#{resource} must be positive"
      end
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
mix test test/armchair_metropolist/domain/entities/node_test.exs
```

Expected: FAIL with `UndefinedFunctionError` — `Node.negative_resources/0 is undefined`.

- [ ] **Step 3: Add the attribute**

In `lib/armchair_metropolist/domain/entities/node.ex`, immediately after the `@statuses` attribute (~:40):

```elixir
  # Resources where a rising figure is bad. For these, a production-table entry is
  # *removal* capacity and a consumption-table entry is *emission* — `industrial`
  # processes 90 waste, a house emits 10.
  #
  # The numbers stay in the tables they are in today, and must. Production is
  # health-scaled and consumption never is, which is exactly the right asymmetry
  # here: a neglected incinerator processes less, a decaying house still emits full.
  # Moving industrial's 90 to the consumption table to make it "read as removal"
  # would unscale removal from health, and waste would become the one resource
  # neglect cannot punish.
  #
  # Written out rather than derived, for the same reason `@resources` is: this is a
  # design commitment, and a derivation would let a table edit silently change which
  # resources are bads. The *sign convention* is not here — that is presentation,
  # and it lives beside `signed/1` in the LiveView.
  @negative_resources [:waste, :traffic]
```

- [ ] **Step 4: Add the accessors**

In the same file, immediately after `statuses/0` (~:218):

```elixir
  @doc """
  The resources where a rising figure is bad.

  A subset of `resources/0`. Consumers use this to decide a *display* sign: for a
  negative resource the legend shows `consumed - produced`, so `industrial` reads
  -90 because it removes 90 waste and a house reads +10 because it emits 10.
  """
  @spec negative_resources() :: [resource()]
  def negative_resources, do: @negative_resources

  @doc """
  Whether a rising figure in `resource` is bad.
  """
  @spec negative_resource?(resource()) :: boolean()
  def negative_resource?(resource), do: resource in @negative_resources
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
mix test test/armchair_metropolist/domain/entities/node_test.exs
```

Expected: PASS.

- [ ] **Step 6: Run the full suite**

```bash
mix test
```

Expected: PASS. Nothing reads the new functions yet, so no other test can move.

- [ ] **Step 7: Commit**

```bash
git add lib/armchair_metropolist/domain/entities/node.ex test/armchair_metropolist/domain/entities/node_test.exs
git commit -m "feat: name waste and traffic as negative-polarity resources"
```

---

### Task 2: The sign convention and the per-type legend cells

**Files:**
- Modify: `lib/armchair_metropolist_web/live/simulator_live.ex` — `marginal_cell/3` general clause (:759-768), `total_cell/4` `is_nil(produced)` branch (:806-807), `total_cell/4` main branch (:809-820), and a new `net/3` helper
- Test: `test/armchair_metropolist_web/live/simulator_live_test.exs` — add to the `describe "legend"` block (~:397), plus one fixture beside `metrics_with_power_production/2` (~:948)

**Interfaces:**
- Consumes: `Node.negative_resource?/1` from Task 1.
- Produces: `defp net(resource, produced, consumed) :: float()` — private to `SimulatorLive`. Task 3 does **not** use it (the totals row is a pair, not a net).

- [ ] **Step 1: Write the failing tests**

Add three tests inside `describe "legend"` in `test/armchair_metropolist_web/live/simulator_live_test.exs`:

```elixir
    # The whole point of the change: waste and traffic are bads, so a block that
    # removes them reads negative and a block that emits them reads positive.
    test "a negative resource shows removal as negative and emission as positive",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Nothing placed, so these are the per-block marginal figures and the test
      # needs no treasury.
      assert view |> element(~s{[data-cell="industrial-waste"]}) |> render() =~ "-90"
      assert view |> element(~s{[data-cell="residential-waste"]}) |> render() =~ "+10"

      # Traffic is the second negative resource, and it is not a copy of waste in
      # the code — only in `@negative_resources`. Without these two lines, shipping
      # the list as `[:waste]` passes the whole suite.
      assert view |> element(~s{[data-cell="transit_hub-traffic"]}) |> render() =~ "-60"
      assert view |> element(~s{[data-cell="residential-traffic"]}) |> render() =~ "+6"

      # Positive resources in the same test. A flip applied to *every* resource
      # rather than the negative ones satisfies all six assertions above.
      assert view |> element(~s{[data-cell="power_plant-power"]}) |> render() =~ "+120"
      assert view |> element(~s{[data-cell="residential-power"]}) |> render() =~ "-15"
    end

    # Three houses at 15 each is 45, inside the opening grant, but the treasury is
    # raised so the fixture does not depend on the grant's current value.
    @tag treasury: 1_000.0
    test "a negative resource's city total flips too, not only the per-block figure",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> element(~s{button[phx-click="select_type"][phx-value-type="residential"]})
      |> render_click()

      for {x, y} <- [{1, 1}, {2, 1}, {3, 1}] do
        view
        |> element(~s{[phx-click="place"][phx-value-x="#{x}"][phx-value-y="#{y}"]})
        |> render_click()
      end

      # Asserted on `.font-semibold` — the total line's own class — and not on the
      # cell: the cell's text also holds the `+10` marginal, so a cell-level
      # assertion silently matches whichever of the two lines the flip reached.
      #
      # This exercises `total_cell/4`'s `is_nil(produced)` branch, which is the
      # branch that fires for every emitter, because no type both produces and
      # consumes waste. Flipping only the main branch leaves this reading `-30`.
      cell = view |> element(~s{[data-cell="residential-waste"] .font-semibold}) |> render()
      assert cell =~ "+30", "three houses must total +30 waste emitted"
    end

    test "a decaying remover shows its capacity failing, rated → actual", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      send(view.pid, {:city_metrics, metrics_with_industrial_waste(90.0, 45.0)})
      render(view)

      # Both nets flip, not just the rated one. The mutation that flips `rated_net`
      # and leaves `actual_net` alone renders "-90 → +45", which an assertion on
      # either figure alone accepts.
      assert view |> element(~s{[data-cell="industrial-waste"] .font-semibold}) |> render() =~
               "-90 → -45"
    end
```

And add this fixture immediately after `metrics_with_power_production/2` (~:957):

```elixir
  # The negative-resource counterpart to `metrics_with_power_production/2`. Industrial's
  # waste entry is *removal* capacity, and removal is health-scaled, so this is the
  # divergence a decaying incinerator actually produces. Written directly for the same
  # reason: placing real nodes cannot produce an exact rated/actual gap.
  defp metrics_with_industrial_waste(rated, actual) do
    metrics = empty_city_metrics()

    put_in(metrics.by_type[:industrial], %{
      count: 1,
      rated_production: %{waste: rated},
      actual_production: %{waste: actual},
      consumption: %{power: 40.0, water: 25.0, traffic: 8.0, labour: 12.0}
    })
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
mix test test/armchair_metropolist_web/live/simulator_live_test.exs
```

Expected: three failures. The first reports the `industrial-waste` cell rendering `+90` where `-90` was expected; the second reports `-30`; the third reports `+90 → +45`.

- [ ] **Step 3: Add the `net/3` helper**

In `lib/armchair_metropolist_web/live/simulator_live.ex`, immediately above `signed/1` (~:842):

```elixir
  # The sign convention, in one place. For a negative resource a positive figure means
  # the type adds to the problem: `industrial` reads -90 because it removes 90 waste,
  # a house reads +10 because it emits 10.
  #
  # One function rather than a flip at each call site, deliberately. `marginal_cell/3`
  # and both branches of `total_cell/4` read the same two tables, and the
  # `is_nil(produced)` branch is the one that fires for most types on a negative
  # resource — no type both produces and consumes waste, and none does for traffic. So
  # a partial patch leaves every emitter rendering backwards while the two removers
  # look right, which is the shape of defect this legend has shipped before.
  defp net(resource, produced, consumed) do
    if Node.negative_resource?(resource),
      do: consumed - produced,
      else: produced - consumed
  end
```

- [ ] **Step 4: Route `marginal_cell/3` through it**

Replace the general clause (~:759-768):

```elixir
  defp marginal_cell(type, resource, _amenity_marginal_labour) do
    produced = Map.get(Node.production(type), resource)
    consumed = Map.get(Node.consumption(type), resource)

    if is_nil(produced) and is_nil(consumed) do
      "—"
    else
      signed(net(resource, produced || 0.0, consumed || 0.0))
    end
  end
```

- [ ] **Step 5: Route both `total_cell/4` branches through it**

Replace the general clause (~:797-822):

```elixir
  defp total_cell(_type, resource, stats, _amenity_labour) do
    produced = Map.get(stats.rated_production, resource)
    actual = Map.get(stats.actual_production, resource)
    consumed = Map.get(stats.consumption, resource)

    cond do
      is_nil(produced) and is_nil(consumed) ->
        nil

      is_nil(produced) ->
        signed(net(resource, 0.0, consumed))

      true ->
        rated_net = net(resource, produced, consumed || 0.0)
        actual_net = net(resource, actual, consumed || 0.0)

        # Compared as displayed rather than as floats: production scales continuously
        # with health, so most of the time the two differ by a fraction of a unit that
        # `signed/1` then rounds away, and the arrow would point from a number to
        # itself. `SimulationCalculator` makes the same choice one layer down, comparing
        # `{round(health), status}` so sub-pixel drift never surfaces.
        if round(rated_net) == round(actual_net),
          do: signed(rated_net),
          else: "#{signed(rated_net)} → #{signed(actual_net)}"
    end
  end
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
mix test test/armchair_metropolist_web/live/simulator_live_test.exs
```

Expected: PASS.

- [ ] **Step 7: Run the full suite**

```bash
mix test
```

Expected: PASS. The totals row still reads `supplied/demanded` and is untouched by this task.

- [ ] **Step 8: Commit**

```bash
git add lib/armchair_metropolist_web/live/simulator_live.ex test/armchair_metropolist_web/live/simulator_live_test.exs
git commit -m "feat: flip the legend sign for waste and traffic"
```

---

### Task 3: The totals row reads demand against capacity

**Files:**
- Modify: `lib/armchair_metropolist_web/live/simulator_live.ex` — footer header text (:592) and `totals_cell/2` (:826-840)
- Test: `test/armchair_metropolist_web/live/simulator_live_test.exs` — **edit** the existing assertions at :514-515 and :535, and extend the totals test

**Interfaces:**
- Consumes: nothing from Tasks 1-2. This change is polarity-*free*: both orderings unify on demand-first, so `net/3` is not involved.
- Produces: nothing later tasks call.

- [ ] **Step 1: Update the existing totals assertions and add the negative-resource cases**

The existing fixture `metrics_with_distinct_satisfaction/0` (~:908) already carries all four resources with distinct figures — `power: stat(150.0, 120.0)`, `water: stat(35.0, 70.0)`, `waste: stat(60.0, 80.0)`, `traffic: stat(25.0, 100.0)`. Do **not** change it; it is already discriminating on both polarities.

Replace the body of `test "the totals row reports supply, demand and satisfaction per resource"` (~:503-519):

```elixir
    test "the totals row reports demand against capacity, and satisfaction per resource",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      send(view.pid, {:city_metrics, metrics_with_distinct_satisfaction()})
      render(view)

      # Demand first, capacity second, for every resource. The fixture's two figures
      # differ per resource, so a transposed pair reads as wrong rather than as itself.
      assert view |> element(~s{[data-total="power"]}) |> render() =~ "120/150"
      assert view |> element(~s{[data-total="water"]}) |> render() =~ "70/35"

      # The negative resources take the *same* order — that is the point of unifying
      # on demand-first. An ordering swap applied only to waste and traffic passes the
      # two assertions below and fails the two above; one applied only to the positive
      # resources does the reverse. Both pairs are needed.
      assert view |> element(~s{[data-total="waste"]}) |> render() =~ "80/60"
      assert view |> element(~s{[data-total="traffic"]}) |> render() =~ "100/25"

      assert view |> element(~s{[data-total="power"]}) |> render() =~ "100.0%"
      assert view |> element(~s{[data-total="water"]}) |> render() =~ "50.0%"
      assert view |> element(~s{[data-total="waste"]}) |> render() =~ "75.0%"
      assert view |> element(~s{[data-total="traffic"]}) |> render() =~ "25.0%"

      # The header names the order. It is a decision, so a silent revert to
      # supplied/demanded must redden something.
      assert render(view) =~ "demanded/supplied · met this tick"
    end
```

Then change the money assertion at ~:535 from `assert cell =~ "13/23"` to:

```elixir
      assert cell =~ "23/13"
```

Leave the `56.5%` assertion on the line below unchanged — `flow_satisfaction` is `13/23` regardless of display order, and the comment above that test explaining why still holds.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
mix test test/armchair_metropolist_web/live/simulator_live_test.exs
```

Expected: two failures — the totals test (cell renders `150/120`, expected `120/150`) and the money test (renders `13/23`, expected `23/13`).

- [ ] **Step 3: Swap the header text**

In `lib/armchair_metropolist_web/live/simulator_live.ex` at :592:

```elixir
              <th class="text-left" colspan="3">demanded/supplied · met this tick</th>
```

Leave the `colspan` comment block above it exactly as it is — its warning about `colspan` being untestable is unaffected by this change.

- [ ] **Step 4: Swap the two figures in `totals_cell/2`**

Replace `totals_cell/2` (~:824-840):

```elixir
  # `resources` is populated from mount via SummarizeCity, so there is no empty-map
  # case to guard here beyond ordinary defensiveness.
  #
  # Demand first, capacity second, for every resource regardless of polarity. This is
  # what lets one header sentence cover both: for power it reads "drawing 120 of 150
  # available", for waste "generating 80 against 60 of processing". It is also the
  # order `docs/PLAYING.md` already uses for its `tightest resource` column, so the
  # guide and the app no longer disagree about which figure comes first.
  defp totals_cell(resources, resource) do
    case Map.get(resources, resource) do
      nil ->
        "—"

      stats ->
        # `flow_satisfaction`, not `satisfaction`: the two numbers shown are demanded
        # and supplied, both flow-only, so the percentage beside them has to be
        # computed on that same basis or it stops being derivable from what's on
        # screen. For money, `satisfaction` also counts the treasury and would make
        # this cell contradict its own two halves (23/13 while reading 100%).
        "#{round(stats.demanded)}/#{round(stats.supplied)} · " <>
          "#{Float.round(stats.flow_satisfaction * 100, 1)}%"
    end
  end
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
mix test test/armchair_metropolist_web/live/simulator_live_test.exs
```

Expected: PASS. In particular `test "the totals row renders each satisfaction figure once"` (~:552-557), which counts occurrences of `"50.0%"`, must stay green — waste at 75% and traffic at 25% add no second `50.0%`.

- [ ] **Step 6: Run the full suite**

```bash
mix test
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/armchair_metropolist_web/live/simulator_live.ex test/armchair_metropolist_web/live/simulator_live_test.exs
git commit -m "feat: read the totals row as demand against capacity"
```

---

### Task 4: Reword the baseline footnote and re-measure the wrap threshold

**Files:**
- Modify: `lib/armchair_metropolist_web/live/simulator_live.ex` — the footnote paragraph (:617-621), its explanatory comment (:605-616), and possibly the `max-[2335px]` constant (:366)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing.

**Why this is its own task:** that paragraph is, measured 2026-08-06, the *binding* width of the expanded sidebar at 1198px — wider than the nine-column matrix's 927px — and it is what sets `max-[2335px]:flex-row`. Rewording it can silently move the layout at ordinary window sizes. Measure; do not reason.

- [ ] **Step 1: Start the dev server and measure the paragraph as it is now**

```bash
mix phx.server
```

Use `preview_start` with the `.claude/launch.json` entry (create one if absent, with `runtimeExecutable: "mix"`, `runtimeArgs: ["phx.server"]`, `port: 4000`). Then run this in `javascript_tool` and record the number:

```js
(() => {
  const p = [...document.querySelectorAll('p')]
    .find(el => el.textContent.includes('free baseline of 40'));
  if (!p) return 'NOT FOUND — is the legend expanded?';
  const clone = p.cloneNode(true);
  Object.assign(clone.style, {width: 'max-content', position: 'absolute', visibility: 'hidden'});
  p.parentNode.appendChild(clone);
  const w = clone.getBoundingClientRect().width;
  clone.remove();
  return w;
})()
```

Record this as `BEFORE`. The legend must be expanded for the paragraph to exist; if it is not, click `#toggle-legend-detail` first.

- [ ] **Step 2: Reword the paragraph**

Replace :617-621 in `lib/armchair_metropolist_web/live/simulator_live.ex`:

```elixir
      <p :if={@detail} class="mt-1 text-xs opacity-60">
        Totals include the free baseline of 40 for power, water, waste and traffic, which
        belongs to no type — capacity to supply power and water, capacity to absorb waste
        and traffic. Labour and money have no free baseline.
        Labour's total also includes the park amenity; park's own row carries it.
      </p>
```

- [ ] **Step 3: Measure again**

Reload the page and re-run the same snippet. Record as `AFTER`.

**Decision rule:**
- If `AFTER <= BEFORE`, the threshold is unchanged. Leave `max-[2335px]` alone and update the comment's measured figure to `AFTER` with today's date.
- If `AFTER > BEFORE`, raise `max-[2335px]` by `ceil(AFTER - BEFORE)` and update **both** the constant at :366 and the two comments that quote 1198px (:279 and :607, :613).

- [ ] **Step 4: Update the measurement comments**

At :605-616, replace the "Re-measured 2026-08-06" paragraph's figure with the new one and date it 2026-08-07, keeping its warning intact:

```elixir
      <%!-- Hidden with the totals row it explains — and not only for tidiness. A long
            line of prose sets this sidebar's width, so left visible it would hold the
            collapsed sidebar at this paragraph's own width instead of the 359px the
            re-entry line below already imposes, and collapsing would reclaim almost
            nothing. Anything added here must stay short or wrappable.

            Re-measured 2026-08-07, after the negative-polarity reword: expanded, these
            <AFTER>px are not merely a nuisance but the *binding* width of the whole
            sidebar — wider than the nine-column matrix's own 927px — so this paragraph,
            not the table, is what sets the expanded wrap threshold in `render/1`. Edit
            the wording here and that constant needs re-measuring. --%>
```

Substitute the real number for `<AFTER>`.

- [ ] **Step 5: Confirm the layout visually at the threshold**

Resize the browser to just inside and just outside the threshold and confirm the legend still sits beside the grid on the wide side and below it on the narrow side. Tailwind v4 compiles `max-[N]` to `@media (width < N)`, exclusive, so `N` is the first width at which the row layout applies — check at `N` and `N - 1`.

Take a screenshot at the wide setting for the commit message reviewer.

- [ ] **Step 6: Run the full suite**

```bash
mix test
```

Expected: PASS. No test asserts on this paragraph's wording.

- [ ] **Step 7: Commit**

```bash
git add lib/armchair_metropolist_web/live/simulator_live.ex
git commit -m "docs: say the free baseline absorbs waste and traffic"
```

---

### Task 5: The guide's generated tables carry the sign

**Files:**
- Modify: `test/support/playing_guide.ex` — `production_block/0` (:466-503), `consumption_block/0` (:505-525), and a new `signed_num/2` helper beside `num/1` (:658)
- Modify: `docs/PLAYING.md` — the two section headings and captions (~:434-437 and ~:452-456), then regenerate

**Interfaces:**
- Consumes: `Node.negative_resource?/1` from Task 1.
- Produces: `defp signed_num(resource, amount) :: String.t()` — private to `PlayingGuide`.

- [ ] **Step 1: Add the signed renderer**

In `test/support/playing_guide.ex`, immediately above `num/1` (~:658):

```elixir
  # A table cell's *displayed* effect on a resource, sign included, matching the legend's
  # `net/3`. For a negative resource a positive figure means the block adds to the problem:
  # `industrial` removes 90 waste and renders `-90`, a house emits 10 and renders `+10`.
  #
  # ASCII `-`, not U+2212, because that is what `SimulatorLive.signed/1` emits and the guide
  # must not disagree with the screen it describes.
  defp signed_num(resource, amount) do
    amount = if Node.negative_resource?(resource), do: -amount, else: amount

    if amount > 0, do: "+#{num(amount)}", else: num(amount)
  end
```

- [ ] **Step 2: Sign the production block**

In `production_block/0`, replace the `outputs` assignment (~:475-478):

```elixir
        outputs =
          @resources
          |> Enum.filter(&Map.has_key?(produced, &1))
          |> Enum.map_join(", ", fn r -> "#{r} #{signed_num(r, Map.fetch!(produced, r))}" end)
```

- [ ] **Step 3: Sign the consumption block**

In `consumption_block/0`, replace the `cells` assignment (~:513-519). The consumption table holds draws, which are *negative* effects on a positive resource and *positive* effects on a negative one — so the amount is negated before it reaches `signed_num/2`:

```elixir
        cells =
          Enum.map_join(@resources, " | ", fn r ->
            case Map.get(consumption, r) do
              nil -> "—"
              amount -> signed_num(r, -amount)
            end
          end)
```

Check the two polarities by hand before moving on: `commercial` power is a draw of 22 on a positive resource, so `signed_num(:power, -22.0)` gives `-22`; `commercial` waste is a draw of 14 on a negative resource, so `signed_num(:waste, -14.0)` negates again to `+14`. Both correct.

- [ ] **Step 4: Rewrite the two headings and captions in the guide**

In `docs/PLAYING.md`, replace the heading and caption above `<!-- generated:production -->` (~:434-437):

```markdown
### Per-block effect, scaled by health

Each figure is one block's effect on that resource, scaled by the block's health — a plant
at 50% health delivers half. Power, water, labour and money are goods: you want them to
rise. Waste and traffic are bads: you want them to fall.
```

And the heading and caption above `<!-- generated:consumption -->` (~:452-456):

```markdown
### Per-block effect, never scaled by health

The other side of the ledger, and it is **never** scaled by health. This is the mechanic
behind every death spiral: a dying block draws its full power and emits its full waste.
```

- [ ] **Step 5: Regenerate and inspect the diff**

```bash
REGENERATE_PLAYING_GUIDE=1 mix test test/docs/playing_guide_test.exs
```

Then:

```bash
git diff docs/PLAYING.md
```

Expected in the diff:
- `production` block: `| \`industrial\` | waste -90 |`, `| \`park\` | waste -8 |`, `| \`transit_hub\` | traffic -60 |`, and `+` signs on every other entry (`power_plant` `power +120`, `residential` `labour +5, money +1`).
- `consumption` block: the `waste` and `traffic` columns become positive (`residential` waste `+10`, traffic `+6`); every other column gains a `-`.
- **No other generated block changes.** `baseline`, `constants`, `capacities`, `costs`, `opening`, `opening_pace` and `opening_wall` must be byte-identical. If any of them moved, stop — a table value has changed and Global Constraints have been violated.

- [ ] **Step 6: Run the guide test clean**

```bash
mix test test/docs/playing_guide_test.exs
```

Expected: PASS without the regenerate flag, confirming the committed document matches the domain.

- [ ] **Step 7: Run the full suite**

```bash
mix test
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add test/support/playing_guide.ex docs/PLAYING.md
git commit -m "docs: sign the guide's per-block tables by resource polarity"
```

---

### Task 6: Delete the reading instruction and sweep the prose

**Files:**
- Modify: `docs/PLAYING.md` — :469-470 (delete), :92, :267, and audit :175, :265, :286, :323, :341
- Modify: `README.md` — :7
- Test: `test/docs/playing_guide_test.exs` — one new test

**Interfaces:**
- Consumes: nothing.
- Produces: nothing.

- [ ] **Step 1: Write the failing test**

Add to `test/docs/playing_guide_test.exs`:

```elixir
  test "the guide states which resources are bads instead of reinterpreting them" do
    guide = File.read!(@guide)

    # Positive case first: the replacement framing must actually be present, so this
    # fails if the sentence is deleted outright rather than reworded.
    assert guide =~ "Waste and traffic are bads"

    # And the instruction it replaced must be gone. Alone, this refute would pass
    # against a guide with the whole reference section deleted.
    refute guide =~ "as *capacity*",
           "the guide must not tell the reader to reinterpret a resource — that " <>
             "sentence is the bug this change removes"
  end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
mix test test/docs/playing_guide_test.exs
```

Expected: FAIL on the `refute` — the guide still contains `as *capacity*` at :469. (The `assert` passes already: Task 5 added that sentence.)

- [ ] **Step 3: Delete the reading instruction**

Remove these two lines from `docs/PLAYING.md` (~:469-470) entirely:

```markdown
Read `waste` and `traffic` as *capacity*: `industrial` supplies waste processing and
`transit_hub` supplies transit capacity, which residential and commercial then consume.
```

Nothing replaces them. The signed tables and the goods/bads sentence from Task 5 carry this now.

- [ ] **Step 4: Reword the free-baseline sentence**

At `docs/PLAYING.md:92-93` the text currently reads:

```markdown
The city starts with free baseline capacity — 40 each of power, water, waste and
traffic, no infrastructure needed.
```

Replace those two lines with:

```markdown
The city starts with free baseline capacity — 40 each of power, water, waste and
traffic, no infrastructure needed: enough to supply 40 power and 40 water, and enough
to absorb 40 waste and 40 traffic.
```

This matches Task 4's footnote, which is the same fact stated on screen.

- [ ] **Step 5: Reword the falling-output sentence**

At `docs/PLAYING.md:267`, "its falling waste output drags the rest of the city" describes a mechanism that is still exactly true, in words that now read backwards. Change `waste output` to `waste processing`:

```markdown
from the very first tick, decays, and its falling waste processing drags the rest of the city
```

- [ ] **Step 6: Confirm the five remaining hits need no edit**

These five were audited when this plan was written and **none of them needs changing**. Read each one to confirm nothing has shifted, then move on — do not reword them:

| line | text | why it survives |
|---|---|---|
| :175 | "then waste for the rest of the run" | Names waste as the binding constraint. Satisfaction is polarity-agnostic, so this is true either way. |
| :265 | "full satisfaction on power, water, waste and traffic simultaneously" | A list of resource names. |
| :286 | "let them heal on power, water, waste and traffic alone" | A list of resource names. |
| :323 | "Housing's list is power, water, waste and traffic — every one of which has a free baseline" | A list, plus a baseline claim that stays true: waste's baseline is 40 of absorption. |
| :341 | "the house's own list is power, water, waste and traffic" | A list of resource names. |

The pattern is the one from `mechanism-prose-survives-classification-prose-does-not`: sentences describing how waste *flows* survive a polarity change untouched; only sentences handing out a verdict about it needed rewriting, and those are :92 and :267, done in Steps 4 and 5. If a new hit appears that is neither a bare list nor a mechanism, reword it and note it in the commit message.

```bash
rg -n "waste" docs/PLAYING.md
```

- [ ] **Step 7: Reword the README**

`README.md:7-8` currently reads:

```markdown
resources — power, water, waste, traffic, labour and money — as supply against
demand; starved nodes lose health and eventually go offline, which removes their
```

Replace with:

```markdown
resources — power, water, waste, traffic, labour and money — as demand against
capacity; starved nodes lose health and eventually go offline, which removes their
```

"Capacity" covers both polarities — capacity to supply power, capacity to absorb waste — where "supply against demand" only reads correctly for the goods.

- [ ] **Step 8: Run the tests to verify they pass**

```bash
mix test test/docs/playing_guide_test.exs
```

Expected: PASS.

- [ ] **Step 9: Run the full suite**

```bash
mix test
```

Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add docs/PLAYING.md README.md test/docs/playing_guide_test.exs
git commit -m "docs: drop the read-as-capacity instruction for waste and traffic"
```

---

## Final verification

- [ ] **Read the whole legend on screen.** Start the server, expand the legend, and confirm: `industrial` waste reads `-90`, `residential` waste `+10`, `transit_hub` traffic `-60`, `power_plant` power `+120`. The totals row reads demand first. Nothing in the sidebar has moved horizontally.
- [ ] **Confirm the constraint held:** `git diff main -- lib/armchair_metropolist/domain/services/ lib/armchair_metropolist/domain/entities/simulation_metrics.ex` must be **empty**. Any output here means the design was violated.
- [ ] **Confirm no table value moved:** `git diff main -- lib/armchair_metropolist/domain/entities/node.ex` must show only the `@negative_resources` attribute and its two accessors, with all three tables untouched.
