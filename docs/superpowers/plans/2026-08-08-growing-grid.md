# Growing Grid Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A new city starts on a 2×2 grid and opens two more rows and columns each time it fills past 70%, capped at 32×32, with cell size shrinking from 128px to 24px so the rendered grid grows from 256px to 768px and then holds.

**Architecture:** `CityMap` owns the growth rule as a pure function (`grow_if_crowded/1`). `UseCases.ManageInfrastructure.place/4` applies it after placing a node. `CityEngine` notices growth by comparing widths and broadcasts `{:city_grew, city_map}`. `SimulatorLive` derives cell size from the map's dimensions and re-streams every node on growth, because LiveView stream entries do not re-render when an assign changes.

**Tech Stack:** Elixir, Phoenix LiveView 1.2.8, ExUnit, StreamData (property tests).

**Spec:** `docs/superpowers/specs/2026-08-08-ring-growth-grid-design.md`. Read §1–§3 and §6 before starting. This plan implements that spec; where they disagree, the spec is right and the plan has a bug.

## Global Constraints

- **Growth is anchored at the origin.** `grow/1` only increments `width` and `height`. It must never touch `nodes`, `x`, `y` or `id`. Spec §9 explains what breaks if it does; a test in Task 1 enforces it.
- **Threshold is integer arithmetic:** `node_count * 10 > 7 * width * height`. No floats, no `0.7`.
- `@initial_size 2`, `@max_size 32`, `@fill_numerator 7`, `@fill_denominator 10` — all on `CityMap`.
- `@min_cell 24`, `@max_cell 128`, `@target_px 768` — all on `SimulatorLive`. **128 is measured, not chosen** (spec §3); do not "tidy" it to 96 or 100.
- Run `mix test` after every task. Run `mix precommit` before every commit — it is `compile --warnings-as-errors`, `deps.unlock --unused`, `format`, `test`.
- Commit messages: conventional prefix (`feat:`, `test:`, `docs:`, `refactor:`), and end with `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.
- Branch is `ring-growth-grid`. Do not merge to `main`.
- Never write a retired atom or a stale constant into a test. If a test needs a figure from the code, reference the function (`CityMap.opening_grant()`), do not restate the literal.
- **`SimulatorLive` has no catch-all `handle_info/2`.** Its clauses end at `:171` and `render/1` follows at `:184`. `Phoenix.LiveView.Channel` calls `view.handle_info/2` whenever the function is exported, so an unmatched message raises `FunctionClauseError` and **kills the LiveView** — it does not log and continue. `CityEngine` *does* have a catch-all (`city_engine.ex:410`); do not confuse the two. Any task that changes a broadcast's shape must land the matching LiveView clause in the same commit.
- **Line numbers in this plan are as of commit `8f0da1a`** and drift as tasks land — Task 2 inserts ~20 lines into `simulator_live.ex` above every anchor Task 5 uses, and Task 4 inserts ~20 into `city_engine.ex` above every anchor Task 6 uses. Treat every `file:line` as a hint and **locate the code by its content**, not by seeking to the line.

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `lib/armchair_metropolist/domain/entities/city_map.ex` | the growth rule, the size constants, `new/0` | 1 |
| `test/armchair_metropolist/domain/entities/city_map_test.exs` | growth rule tests; **rewrite** the `reset/1` test | 1 |
| `test/armchair_metropolist/use_cases/reset_city_test.exs` | **rewrite** one assertion | 1 |
| `lib/armchair_metropolist_web/live/simulator_live.ex` | derived cell size, `assign_grid/2`, growth + reset handlers | 2, 5 |
| `lib/armchair_metropolist/use_cases/manage_infrastructure.ex` | applies growth after a placement | 3 |
| `lib/armchair_metropolist/infrastructure/simulation/city_engine.ex` | growth detection, broadcasts, `new_city_map/0` | 4, 6 |
| `config/config.exs` | delete `grid_width` / `grid_height` | 6 |
| `docs/PLAYING.md`, three docstrings | player-facing and API documentation | 7 |

**Task ordering keeps the suite green after every task except Task 6.** Tasks 1–5 leave `new_city_map/0` on the config-driven 40×30, so no existing test sees a 2×2 and growth never fires in existing fixtures. Task 6 flips the default and migrates the tests that break, in one commit.

---

### Task 1: `CityMap` owns the growth rule

**Files:**
- Modify: `lib/armchair_metropolist/domain/entities/city_map.ex:55-88`
- Modify: `test/armchair_metropolist/domain/entities/city_map_test.exs:44-70`
- Modify: `test/armchair_metropolist/use_cases/reset_city_test.exs:18`

**Interfaces:**
- Produces: `CityMap.new/0` → `t()` (a 2×2 empty city). `CityMap.grow_if_crowded(t()) :: t()`.
- Consumes: nothing.

- [ ] **Step 1: Write the failing tests**

Add to `test/armchair_metropolist/domain/entities/city_map_test.exs`:

```elixir
  describe "new/0" do
    test "starts a city on the initial 2x2 grid with the opening grant" do
      map = CityMap.new()

      assert map.width == 2
      assert map.height == 2
      assert map.tick == 0
      assert map.nodes == %{}
      assert map.money == CityMap.opening_grant()
    end

    test "the struct defaults agree with new/0 on the starting grid" do
      # `CityEngine.normalize_city_map/1` merges every decoded snapshot onto a fresh
      # `%CityMap{}`, so the struct defaults are what a stored city inherits for a field
      # it lacks. A literal in `defstruct` beside a different `@initial_size` desyncs the
      # two on a path only cold loads exercise -- the same trap the `@opening_grant`
      # comment above `defstruct` describes. No other test in this suite sees it.
      assert %CityMap{}.width == CityMap.new().width
      assert %CityMap{}.height == CityMap.new().height
    end
  end

  describe "grow_if_crowded/1" do
    # The threshold is pinned by three sizes, not one. Each size alone admits an interval
    # of thresholds that would pass it, and only the intersection is narrow:
    #   2x2 fires at 3, not 2  =>  t in [0.5, 0.75)     kills 0.75 and 0.8, spares 0.6
    #   4x4 fires at 12, not 11 => t in [0.6875, 0.75)  kills 0.6 (fires at 10), 0.65 (11)
    #   6x6 fires at 26, not 25 => t in [0.6944, 0.7222) kills 0.69 (fires at 25)
    # Dropping any one of these leaves a wrong constant passing.
    test "a 2x2 opens on its third block and not its second" do
      refute grown?(crowd(CityMap.new(2, 2), 2))
      assert grown?(crowd(CityMap.new(2, 2), 3))
    end

    test "a 4x4 opens on its twelfth block and not its eleventh" do
      refute grown?(crowd(CityMap.new(4, 4), 11))
      assert grown?(crowd(CityMap.new(4, 4), 12))
    end

    test "a 6x6 opens on its twenty-sixth block and not its twenty-fifth" do
      refute grown?(crowd(CityMap.new(6, 6), 25))
      assert grown?(crowd(CityMap.new(6, 6), 26))
    end

    test "growth adds two to both dimensions" do
      grown = CityMap.grow_if_crowded(crowd(CityMap.new(2, 2), 4))

      # Both asserted: a `+1` mutant gives 3x3 and a one-axis mutant gives 4x2.
      assert grown.width == 4
      assert grown.height == 4
    end

    test "growth leaves every node exactly where it was" do
      # The anchoring invariant, and the reason this design needs no generation fence on
      # coordinate-addressed commands. See spec section 9: a growth that moved the origin
      # would make an in-flight click resolve to a *different* cell, because the old and
      # new coordinate sets overlap. Comparing `nodes` by `==` catches any translation.
      crowded =
        Enum.reduce([{0, 0}, {1, 0}, {0, 1}, {1, 1}], CityMap.new(2, 2), fn {x, y}, map ->
          CityMap.put_node(map, Node.new(x, y, :park))
        end)

      grown = CityMap.grow_if_crowded(crowded)

      assert grown.width == 4
      assert grown.nodes == crowded.nodes
      assert Map.keys(grown.nodes) |> Enum.sort() == ["0:0", "0:1", "1:0", "1:1"]
    end

    test "growth stops at the cap" do
      # 717 nodes, not a handful: `n * 10 > 7 * 1024` needs `n >= 717`, so a sparsely
      # filled 32x32 does not grow under the correct code *or* under a cap-less mutant,
      # and a smaller fixture would pass either way.
      refute grown?(crowd(CityMap.new(32, 32), 717))
    end

    test "a city whose height alone is at the cap does not grow" do
      # 30x40 rather than the legacy 40x30 shape, deliberately. With width 40 both
      # `width < @max_size` and `max(width, height) < @max_size` are already false, so a
      # 40x30 fixture cannot separate them. Only `width < 32 <= height` makes the
      # `width`-only mutant grow where the correct predicate refuses.
      refute grown?(crowd(CityMap.new(30, 40), 841))
    end

    test "the legacy 40x30 grid does not grow" do
      # Every city stored before this change is 40x30. Asserted for its own sake: leaving
      # them alone is the point of the cap check, not a side effect of it.
      refute grown?(crowd(CityMap.new(40, 30), 841))
    end

    test "demolishing does not take rows away" do
      # A guard against a future shrink path, not a mutation kill: `grow_if_crowded/1` is
      # the only size-changing function and `delete_node/3` never calls it, so no mutation
      # of today's implementation can fail this. Do not count it as coverage.
      grown = CityMap.grow_if_crowded(crowd(CityMap.new(2, 2), 4))
      shrunk = Enum.reduce([{0, 0}, {1, 0}], grown, fn {x, y}, m -> CityMap.delete_node(m, x, y) end)

      assert shrunk.width == 4
      assert shrunk.height == 4
    end
  end

  # `n` distinct nodes, laid out by index across the map's own width so the fixture works
  # at every grid size this suite uses.
  defp crowd(map, n) do
    Enum.reduce(0..(n - 1), map, fn i, acc ->
      CityMap.put_node(acc, Node.new(rem(i, map.width), div(i, map.width), :park))
    end)
  end

  defp grown?(map), do: CityMap.grow_if_crowded(map) != map
```

Then **rewrite** the existing `reset/1` test at `city_map_test.exs:44-70`. Its name and its assertions both state the old behaviour:

```elixir
  describe "reset/1" do
    test "starts a new city on a fresh 2x2 grid, discarding everything else" do
      city =
        CityMap.new(12, 7)
        |> CityMap.put_node(Node.new(1, 1, :power_plant))
        |> CityMap.debit(100.0)

      city = %{city | tick: 412}

      reset = CityMap.reset(city)

      # Each property named separately: a reset that forgets one of these is a real bug
      # and a single `==` against a literal struct would not say which.
      assert reset.width == 2
      assert reset.height == 2
      assert reset.tick == 0
      assert reset.nodes == %{}
      assert reset.money == CityMap.opening_grant()
    end

    test "delegates to new/0 so there is one definition of a new city" do
      city = CityMap.put_node(CityMap.new(40, 30), Node.new(3, 3, :commercial))

      # The grid does *not* survive a reset. A reset city is a new city in every respect,
      # which is what keeps `new/0` the single definition of one.
      assert CityMap.reset(city) == CityMap.new()
    end
  end
```

And at `test/armchair_metropolist/use_cases/reset_city_test.exs:18`, change:

```elixir
    assert reset == CityMap.new()
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/armchair_metropolist/domain/entities/city_map_test.exs test/armchair_metropolist/use_cases/reset_city_test.exs`

Expected: FAIL. `CityMap.new/0` and `CityMap.grow_if_crowded/1` are undefined, and the two rewritten assertions fail against the current `reset/1`.

- [ ] **Step 3: Implement**

In `lib/armchair_metropolist/domain/entities/city_map.ex`, add the four attributes immediately above `defstruct` (below the existing `@opening_grant` and its comment):

```elixir
  # The grid a new city starts on. A city opens two more rows and columns whenever more
  # than 70% of its cells are occupied, up to `@max_size`.
  #
  # Referenced by `defstruct` below rather than restated there. `CityEngine`'s
  # `normalize_city_map/1` merges every decoded snapshot onto a fresh `%CityMap{}`, so the
  # struct defaults are what a stored city inherits for any field it lacks — exactly the
  # split the `@opening_grant` comment above describes. A literal in `defstruct` beside a
  # different value here desyncs them on a path only cold loads exercise.
  @initial_size 2

  # Growth stops here. This bounds the data structure, not the game: reaching a 32x32
  # takes 631 blocks, some 9,465 in construction costs, far past anything a player reaches.
  # It also keeps every stored 40x30 city off the ladder, since 40 exceeds it.
  @max_size 32

  # The occupancy that opens a new pair of rows, as a ratio rather than a float, so the
  # trigger is integer arithmetic and never a float comparison.
  #
  # 70% and not 80%: at 80% the boundary on a 2x2 is 3.2, so the starter grid alone had to
  # be completely full before it would open. At 70% no size on the ladder does.
  @fill_numerator 7
  @fill_denominator 10

  defstruct width: @initial_size,
            height: @initial_size,
            tick: 0,
            nodes: %{},
            money: @opening_grant,
            waste_stock: 0.0
```

Replace `new/2`'s doc and add `new/0`; replace `reset/1`:

```elixir
  @doc """
  Create a new city on the starting grid.

  The one definition of what a new city is. `new/2` exists for fixtures that want a grid
  large enough that capacity never binds; it is *not* how a stored city is rebuilt, which
  goes through `CityEngine.normalize_city_map/1` and the struct defaults.
  """
  @spec new() :: t()
  def new, do: new(@initial_size, @initial_size)

  @doc """
  Open two more rows and columns if the grid is more than 70% occupied, else return `map`.

  **Growth is anchored at the origin**: the two rows and two columns appear at the right
  and bottom edges, and every existing node keeps its `x`, `y` and `id`. `nodes` is not
  rebuilt and not re-keyed.

  That is load-bearing, not incidental. A click carries `phx-value-x` / `phx-value-y` baked
  into the DOM at render time, and the browser's DOM is stale for a full round trip after a
  growth, so commands composed against the old grid keep arriving afterwards. Because the
  origin does not move, `(3, 4)` names the same cell before and after and those commands
  are still correct. A version that recentred the city would reinterpret them — and since
  the old and new coordinate sets overlap, they would not fail, they would hit a
  *different* cell. That variant needs a generation token on every coordinate-addressed
  command; this one needs nothing. See the design doc's "Why growth is anchored".
  """
  @spec grow_if_crowded(t()) :: t()
  def grow_if_crowded(map) do
    if max(map.width, map.height) < @max_size and crowded?(map) do
      %{map | width: map.width + 2, height: map.height + 2}
    else
      map
    end
  end

  defp crowded?(map) do
    map_size(map.nodes) * @fill_denominator >
      @fill_numerator * map.width * map.height
  end

  @doc """
  Discard this city and start a new one.

  Tick 0, no nodes, the treasury back to `opening_grant/0`, and the grid back to the
  starting size — delegating to `new/0` rather than resetting fields by hand, so there is
  exactly one definition of what a new city is and this cannot drift from it.

  The grant has to come back. A collapsed city's treasury has drained to zero and the
  cheapest block costs 15, so a wipe that cleared the grid and left the balance alone would
  trade one dead end for another.
  """
  @spec reset(t()) :: t()
  def reset(_map), do: new()
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/armchair_metropolist/domain/entities/city_map_test.exs test/armchair_metropolist/use_cases/reset_city_test.exs`
Expected: PASS.

- [ ] **Step 5: Run the whole suite**

Run: `mix test`

Expected: PASS. `reset/1` no longer reads its argument, so if anything else asserted the old grid-preserving behaviour it fails here — fix those tests to the new behaviour, do not weaken the implementation.

- [ ] **Step 6: Mutation-verify the three threshold tests**

Do not skip this. Temporarily change `@fill_numerator` to `3` (i.e. 0.75) and run
`mix test test/armchair_metropolist/domain/entities/city_map_test.exs` — with `@fill_denominator 4`. Expected: the 2×2, 4×4 and 6×6 tests fail. Then try `@fill_numerator 69, @fill_denominator 100`. Expected: **only** the 6×6 test fails. If the 6×6 test passes under 0.69, the fixture is wrong and the constant is not pinned.

**Restore the original values with `git diff` / a manual edit, never with `git checkout`** — the working tree holds uncommitted work from this task.

- [ ] **Step 7: Commit**

```bash
git add lib/armchair_metropolist/domain/entities/city_map.ex test/armchair_metropolist/domain/entities/city_map_test.exs test/armchair_metropolist/use_cases/reset_city_test.exs
mix precommit
git commit -m "feat: give CityMap a growth rule and a 2x2 starting grid

grow_if_crowded/1 opens two rows and columns above 70% occupancy, up to
32x32, anchored at the origin so no node is re-keyed. reset/1 now returns a
new/0 city rather than preserving the old grid.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Derive cell size in the LiveView

A pure refactor. `new_city_map/0` still yields 40×30, and `cell_size(40, 30)` is 24 — today's constant — so this task must not change a single rendered pixel.

**Files:**
- Modify: `lib/armchair_metropolist_web/live/simulator_live.ex:31` (the `@cell_size` attribute), `:80-99` (`do_mount/3`'s assigns)
- Modify: `test/armchair_metropolist_web/live/simulator_live_test.exs`

**Interfaces:**
- Consumes: `CityMap.new/0`, `CityMap.max_size/0` from Task 1.
- Produces: `assign_grid(socket, %CityMap{}) :: Socket.t()` setting `:width`, `:height`, `:cell_size`, `:grid_cells`. Tasks 5 calls it from two more sites.

- [ ] **Step 1: Write the failing tests**

Add to `test/armchair_metropolist_web/live/simulator_live_test.exs`, in a new `describe "grid geometry"` block:

```elixir
  describe "grid geometry" do
    # Cell size is `min(128, max(24, div(768, max(width, height))))`. Each case below kills
    # a different clamp, and the assignment of case to clamp is not interchangeable:
    #
    #   2x2 -> 128 and 4x4 -> 128 kill the *ceiling*: without `min/2` they are 384 and 192.
    #   6x6 -> 128 kills nothing, because div(768, 6) is exactly 128. Kept as a boundary
    #     case; it is as blind to the ceiling as 8x8 is.
    #   40x30 -> 24 and 20x40 -> 24 both kill the *floor*: div(768, 40) is 19 for either, so
    #     dropping `max/2` returns 19 from both. None of the square sizes can -- dropping the
    #     floor leaves 2x2, 4x4, 6x6, 8x8 and 32x32 all unchanged.
    #   20x40 -> 24 kills `div(768, width)` in place of `max(width, height)`, which gives 38.
    test "cell size shrinks as the grid grows, clamped at both ends" do
      assert SimulatorLive.cell_size(2, 2) == 128
      assert SimulatorLive.cell_size(4, 4) == 128
      assert SimulatorLive.cell_size(6, 6) == 128
      assert SimulatorLive.cell_size(8, 8) == 96
      assert SimulatorLive.cell_size(32, 32) == 24
    end

    test "the floor keeps a legacy 40x30 grid at today's cell size" do
      assert SimulatorLive.cell_size(40, 30) == 24
    end

    test "cell size is driven by the longer axis" do
      assert SimulatorLive.cell_size(20, 40) == 24
    end

    # Tagged, deliberately. `@tag treasury:` seeds an explicit `CityMap.new(40, 30)`, which
    # is what this test's name claims it is testing. Untagged it would ride the fresh-city
    # path, and Task 6 makes that a 2x2 and adds a test asserting 256px on the same path —
    # the two would contradict each other and one would have to be deleted.
    @tag treasury: 400.0
    test "a stored 40x30 city renders at exactly today's size", %{conn: conn} do
      # Pins "no existing city changes appearance". 40 * 24 by 30 * 24.
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, ~s{[style*="width: 960px; height: 720px;"]})
    end
  end
```

Note the `SimulatorLive` alias: add `alias ArmchairMetropolistWeb.SimulatorLive` to the test module if absent.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/armchair_metropolist_web/live/simulator_live_test.exs`

Expected: FAIL with `SimulatorLive.cell_size/2 is undefined or private`.

- [ ] **Step 3: Implement**

Replace `simulator_live.ex:31`:

```elixir
  # Cell size is derived from the grid, not fixed, because the grid grows. The rendered
  # footprint runs 256px (2x2) -> 512px (4x4) -> 768px (6x6) and then holds between 748px
  # and 768px while cells shrink to @min_cell at the 32x32 cap.
  #
  # @max_cell 128 is *measured*, not chosen for looks. The collapse banner is styled to the
  # grid's own width, and its widest headline (":locked") needs a 245px banner to wrap to
  # two lines rather than three. 2 * 128 = 256 clears that with 11px of slack. 96 would
  # give 192px against a 193px three-line threshold — one pixel short, on a boundary that
  # is bistable. 128 also divides @target_px exactly, so every cell on the ramp is an
  # integer. Do not change these without re-measuring; see the design doc's "Why 128".
  #
  # @min_cell 24 is today's fixed value, which is what keeps a stored 40x30 city
  # pixel-identical: div(768, 40) is 19, clamped up to 24, giving the same 960x720.
  @min_cell 24
  @max_cell 128
  @target_px 768

  @doc false
  # Public only so the test suite can pin the clamps directly rather than inferring them
  # from rendered markup at five grid sizes.
  @spec cell_size(pos_integer(), pos_integer()) :: pos_integer()
  def cell_size(width, height) do
    min(@max_cell, max(@min_cell, div(@target_px, max(width, height))))
  end
```

Replace `do_mount/3`'s assign block at `:80-99`. The four grid assigns move into `assign_grid/2`:

```elixir
    socket =
      socket
      |> assign_grid(city_map)
      |> assign(:metrics, metrics)
      |> assign(:node_types, Node.types())
      |> assign(:selected_type, List.first(Node.types()))
      |> assign(:legend_detail, true)
      # False only on the desktop target (see mount/3): a recovery code the desktop
      # cannot use — there is no "elsewhere" to return to it from, and it would
      # change on every launch — is worse than none.
      |> assign(:show_reentry?, Keyword.fetch!(opts, :show_reentry?))
      |> stream(:nodes, CityMap.nodes(city_map), dom_id: & &1.id)

    {:ok, socket}
  end

  # The four assigns that describe the grid, in one place, because they have to move
  # together: `:cell_size` is a function of the dimensions and `:grid_cells` is a function
  # of both. Called from mount, from a growth, and from a reset — reassigning `:width`
  # without the others is the bug this exists to prevent.
  defp assign_grid(socket, %CityMap{} = city_map) do
    grid_cells =
      for y <- 0..(city_map.height - 1), x <- 0..(city_map.width - 1), do: {x, y}

    socket
    |> assign(:width, city_map.width)
    |> assign(:height, city_map.height)
    |> assign(:cell_size, cell_size(city_map.width, city_map.height))
    |> assign(:grid_cells, grid_cells)
  end
```

- [ ] **Step 4: Comment the headline that sets `@max_cell`**

`@max_cell 128` is derived from one string — the `:locked` headline — and no Elixir test can
measure text, so the only guard is a note where a future editor will see it. Above the
`:locked` headline `<p>` in `collapse_banner/1`, add:

```elixir
      <%!-- Width-constrained. This is the widest of the four headlines (417px at
            max-content, measured 2026-08-08 at 16px/600 in ui-sans-serif) and it is what
            sets `@max_cell 128`: the banner shares the grid's width, a 2x2 grid is 256px,
            and this line needs a 245px banner to wrap to two lines rather than three.
            There are 11px of slack. Lengthening this sentence spends them, and no test
            will tell you -- Elixir cannot measure text. Re-measure in the browser. --%>
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/armchair_metropolist_web/live/simulator_live_test.exs`
Expected: PASS, including every pre-existing test in that file. If the banner-width test at `:1332` fails, `cell_size(40, 30)` is not returning 24 and the clamps are wrong.

- [ ] **Step 6: Commit**

```bash
git add lib/armchair_metropolist_web/live/simulator_live.ex test/armchair_metropolist_web/live/simulator_live_test.exs
mix precommit
git commit -m "refactor: derive grid cell size from the city map

Replaces the fixed @cell_size 24 with min(128, max(24, div(768, longer axis)))
and gathers the four grid assigns into assign_grid/2, so cell size and
grid_cells cannot be updated without each other.

No rendered change: the default grid is still 40x30 and div(768, 40) clamps
up to 24, giving the same 960x720.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Apply growth when a node is placed

**Files:**
- Modify: `lib/armchair_metropolist/use_cases/manage_infrastructure.ex:36-45`
- Modify: `test/armchair_metropolist/use_cases/manage_infrastructure_test.exs`

**Interfaces:**
- Consumes: `CityMap.grow_if_crowded/1` from Task 1.
- Produces: `place/4` still returns `{:ok, {CityMap.t(), Node.t()}}`, with the map possibly grown. Task 4 detects growth by comparing `city_map.width`.

- [ ] **Step 1: Write the failing test**

Add to `test/armchair_metropolist/use_cases/manage_infrastructure_test.exs`:

```elixir
  describe "place/4 and grid growth" do
    test "the placement that crosses 70% opens the grid, and the node is on it" do
      # Exactly two nodes, then place the third. The count is load-bearing: growth runs
      # *after* the put, so it counts three and grows. A mutant that grows before the put
      # counts two, 20 > 28 is false, and it does not grow. Start from a map already over
      # threshold (three nodes, placing a fourth) and both grow — the mutant survives.
      two =
        CityMap.new(2, 2)
        |> CityMap.put_node(Node.new(0, 0, :park))
        |> CityMap.put_node(Node.new(1, 0, :park))

      assert {:ok, {grown, node}} = ManageInfrastructure.place(two, 0, 1, :park)

      assert grown.width == 4
      assert grown.height == 4
      assert node.id == "0:1"
      assert CityMap.get_node(grown, 0, 1).type == :park
      assert map_size(grown.nodes) == 3
    end

    test "a placement below the threshold leaves the grid alone" do
      one = CityMap.put_node(CityMap.new(2, 2), Node.new(0, 0, :park))

      assert {:ok, {same, _node}} = ManageInfrastructure.place(one, 1, 0, :park)

      assert same.width == 2
      assert same.height == 2
    end

  end
```

**Do not add a "a refused placement never grows the grid" test.** It cannot fail: `place/4`'s
error branches return `{:error, reason}` and no map, so growth on a refusal is unobservable
at this layer under any mutation of the implementation below. The only assertion available is
`{:error, :occupied}`, which `manage_infrastructure_test.exs:28` and `city_engine_test.exs:309`
already make. Putting growth on the success branch of the `cond` is what makes it true, and
nothing at this layer can check it.

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/armchair_metropolist/use_cases/manage_infrastructure_test.exs`
Expected: FAIL — `grown.width` is 2, not 4.

- [ ] **Step 3: Implement**

In `manage_infrastructure.ex`, change only the success branch of `place/4`'s `cond`:

```elixir
      true ->
        node = Node.new(x, y, type)

        city_map =
          city_map
          |> CityMap.put_node(node)
          |> CityMap.debit(Node.construction_cost(type))
          # After the put, so the occupancy test counts the node just placed. Growth lives
          # here rather than in `CityMap.put_node/2` because `put_node/2` is a primitive
          # that sets one key: a growth policy inside it would reach every caller,
          # including fixtures that build a city of a chosen size, and there would then be
          # no way to build one at all.
          |> CityMap.grow_if_crowded()

        {:ok, {city_map, node}}
```

Extend `place/4`'s `@doc` with a line noting that the returned map may have grown.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/armchair_metropolist/use_cases/manage_infrastructure_test.exs`
Expected: PASS.

- [ ] **Step 5: Run the whole suite**

Run: `mix test`

Expected: PASS. Every existing fixture builds on `CityMap.new(40, 30)`, where `max(40, 30)` is at the cap, so growth cannot fire. `test/support/city_generators.ex` generates 6..12 grids with at most 12 nodes — under threshold at every size it produces. If the `PlayingGuide` doc test fails, growth has fired somewhere it should not have.

- [ ] **Step 6: Commit**

```bash
git add lib/armchair_metropolist/use_cases/manage_infrastructure.ex test/armchair_metropolist/use_cases/manage_infrastructure_test.exs
mix precommit
git commit -m "feat: grow the grid when a placement crosses 70% occupancy

Applied after the put, so the occupancy test counts the node just placed, and
on the success path only.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Broadcast growth, and carry the map on reset

> **Tasks 4 and 5 are one commit.** This task changes `:city_reset` from a bare atom to a
> tuple and adds `{:city_grew, …}`; Task 5 adds the LiveView clauses that match them. In
> between, the view has no clause for either message — and `SimulatorLive` has **no
> catch-all `handle_info/2`**, so it raises `FunctionClauseError` and dies rather than
> logging. Do Task 4, then Task 5, then commit once at the end of Task 5. Task 4 has no
> commit step.

**Files:**
- Modify: `lib/armchair_metropolist/infrastructure/simulation/city_engine.ex:36-42` (moduledoc inventory), `:278-291` (`handle_call({:place, …})`), `:323` (the reset broadcast), `:157` (`reset/1`'s `@doc`)
- Modify: `test/armchair_metropolist/infrastructure/simulation/city_engine_test.exs`

**Interfaces:**
- Consumes: `place/4`'s possibly-grown map from Task 3.
- Produces: two broadcast shapes for Task 5 — `{:city_grew, %CityMap{}}` and `{:city_reset, %CityMap{}}`. The latter **replaces** the bare `:city_reset` atom.

- [ ] **Step 1: Write the failing tests**

Add to `test/armchair_metropolist/infrastructure/simulation/city_engine_test.exs`. These need a small seeded grid, so they use `StubSnapshotRepository.set_initial/1` with a 2×2 rather than the `{:error, :not_found}` default:

```elixir
  describe "grid growth" do
    setup %{city_id: city_id} do
      two =
        CityMap.new(2, 2)
        |> CityMap.put_node(Node.new(0, 0, :park))
        |> CityMap.put_node(Node.new(1, 0, :park))

      StubSnapshotRepository.set_initial({:ok, {0, two}})
      start_supervised!({CityEngine, city_id: city_id})
      Phoenix.PubSub.subscribe(ArmchairMetropolist.PubSub, CityEngine.topic(city_id))
      :ok
    end

    test "broadcasts the grown map before the node that grew it", %{city_id: city_id} do
      assert {:ok, _node} = CityEngine.place(city_id, 0, 1, :park)

      # Received with a catch-all and *then* matched, deliberately. `assert_receive` scans
      # the whole mailbox, so two `assert_receive`s in sequence pass in either order and
      # would not pin the ordering at all. A subscriber that sees the node before the
      # resize paints it onto a grid that is still 2x2.
      assert_receive first when is_tuple(first)
      assert match?({:city_grew, %CityMap{width: 4, height: 4}}, first)

      assert_receive second when is_tuple(second)
      assert match?({:city_node_placed, %Node{id: "0:1"}}, second)

      assert_receive {:city_metrics, %{node_count: 3}}
    end

    test "does not announce growth on a placement that did not grow", %{city_id: city_id} do
      # The 2x2 holds two nodes; a third grows it, so demolish one first and place into a
      # map that stays at 2x2.
      assert {:ok, _id} = CityEngine.demolish(city_id, 0, 0)
      assert {:ok, _node} = CityEngine.place(city_id, 0, 1, :park)

      refute_receive {:city_grew, _}, 200
      assert_receive {:city_node_placed, %Node{id: "0:1"}}
      # Asserted in this case too, not only in the growing one: an early return that skipped
      # the metrics on the non-growth path would otherwise go unnoticed.
      assert_receive {:city_metrics, %{node_count: 2}}
    end
  end
```

And a reset test in `describe "reset/1"`. **That describe has no shared `setup`** — every test
in it calls `set_initial/1` and `start_supervised!/1` itself. Do the same, or
`CityEngine.reset/1` reaches `CityRegistry.ensure_started/1` and leaves a
DynamicSupervisor-owned engine running past the end of the test, which is the leak this
file's comments were written to prevent:

```elixir
    test "a reset broadcasts the new city map, not a bare atom", %{city_id: city_id} do
      StubSnapshotRepository.set_initial({:ok, {0, CityMap.new(12, 12)}})
      start_supervised!({CityEngine, city_id: city_id})
      Phoenix.PubSub.subscribe(ArmchairMetropolist.PubSub, CityEngine.topic(city_id))

      assert :ok = CityEngine.reset(city_id)

      # The map travels with the message because the view has to resize: a reset returns a
      # 2x2 whatever grid the city had grown to. Seeded at 12x12 so that is visible — from a
      # 2x2 the assertion would hold without `reset/1` changing the grid at all.
      assert_receive {:city_reset, %CityMap{width: 2, height: 2, nodes: nodes}}
      assert nodes == %{}
    end
```

**Also rewrite the existing test that pins the bare atom.** `city_engine_test.exs:1238-1258`
("broadcasts the reset and the new metrics") ends with `assert first == :city_reset`, written
deliberately to pin broadcast order. Change that one line to match the new shape, keeping the
ordering assertion intact:

```elixir
      assert match?({:city_reset, %CityMap{}}, first)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/armchair_metropolist/infrastructure/simulation/city_engine_test.exs`

Expected: FAIL — no `{:city_grew, …}` is ever sent, and the reset test times out waiting for a tuple while the engine sends the atom `:city_reset`.

- [ ] **Step 3: Implement**

In `handle_call({:place, x, y, type}, …)`, replace the body of the `{:ok, {city_map, node}}` branch:

```elixir
      {:ok, {city_map, node}} ->
        metrics = summarize(city_map)

        # Detected by comparing widths against the map this engine already holds, so
        # `ManageInfrastructure.place/4` needs no `:grew` flag in its return and its
        # contract does not change.
        #
        # Sent *before* the node, so a subscriber sizes the grid before the new node lands
        # on it. Carries the whole map because the view must re-stream every node: a
        # LiveView stream does not re-render existing entries when an assign changes, so
        # nodes keep their old pixel geometry across a cell-size change.
        if city_map.width != state.city_map.width do
          broadcast(state.city_id, {:city_grew, city_map})
        end

        broadcast(state.city_id, {:city_node_placed, node})
        # Commands change the city, so subscribers need the new figures now. Without
        # this the legend's counts would not move until the next tick — and in tests,
        # where no clock runs, never.
        broadcast(state.city_id, {:city_metrics, metrics})
        {:reply, {:ok, node}, %{state | city_map: city_map, metrics: metrics}}
```

At `:323`, change the reset broadcast:

```elixir
    broadcast(state.city_id, {:city_reset, city_map})
```

Update the moduledoc inventory at `:36-42` — it enumerates every message the engine sends, so both changes falsify it:

```elixir
  On `topic(city_id)`: `{:city_delta, delta}` on every tick; `{:city_metrics,
  metrics}` on every tick and on every successful `place`/`demolish`;
  `{:city_node_placed, node}` and `{:city_node_removed, id}` on successful commands.
  `{:city_grew, city_map}` immediately *before* `{:city_node_placed, …}` on a placement
  that opened the grid — the view has to resize before the node is painted on it.
  `{:city_reset, city_map}` on a successful `reset/1`, followed by `{:city_metrics,
  metrics}`; it carries the map because a reset returns the city to a 2x2 grid.
  Rejected commands broadcast nothing. Each city's events land on their own topic —
  a shared one would deliver every visitor's deltas to every other visitor.
```

And `reset/1`'s `@doc` at `:157` — "start a new one on the same grid" is now false. Replace "on the same grid" with "on a fresh starting grid".

- [ ] **Step 4: Run the engine tests to verify they pass**

Run: `mix test test/armchair_metropolist/infrastructure/simulation/city_engine_test.exs`
Expected: PASS.

- [ ] **Step 5: Run the whole suite and confirm only the expected failures**

Run: `mix test`

Expected: **FAIL, in `simulator_live_test.exs` only.** Every failure must be a
`FunctionClauseError` from `SimulatorLive.handle_info/2` — the view has no clause for
`{:city_reset, city_map}` and none for `{:city_grew, …}`, and no catch-all, so it dies rather
than ignoring them. Any failure that is *not* that is a real defect in this task; find it
before moving on.

**Do not commit.** Go straight to Task 5, which adds the matching clauses and commits both.

---

### Task 5: The view resizes on growth and on reset

**Files:**
- Modify: `lib/armchair_metropolist_web/live/simulator_live.ex:1-23` (moduledoc), `:107-132` (both `handle_event`s), `:152-173` (`handle_info`s)
- Modify: `test/armchair_metropolist_web/live/simulator_live_test.exs`

**Interfaces:**
- Consumes: `{:city_grew, %CityMap{}}` and `{:city_reset, %CityMap{}}` from Task 4; `assign_grid/2` from Task 2.
- Produces: nothing further.

- [ ] **Step 1: Write the failing tests**

Add to `test/armchair_metropolist_web/live/simulator_live_test.exs`. These drive the view by broadcasting, which is how the other stream tests in this file work:

```elixir
  describe "the view resizes when the grid grows" do
    test "an existing node's geometry follows the new cell size", %{conn: conn} do
      # 6x6 -> 8x8 and NOT 2x2 -> 4x4. This is the whole point of the test: cell size is
      # 128 at 2x2, 4x4 and 6x6, so across those growths correct and broken code emit
      # byte-identical geometry and the test cannot fail. 6x6 -> 8x8 is the first growth
      # that moves cell size, 128 -> 96.
      #
      # A LiveView stream does not re-render existing entries when an assign changes --
      # `LiveStream`'s Enumerable reduces over pending inserts only -- so without an
      # explicit re-stream this node keeps `width: 128px` on a 96px grid.
      {:ok, view, _html} = live(conn, ~p"/")

      # Streamed by {:city_node_placed, ...} BEFORE the growth, deliberately. Introduced
      # through the growth payload instead, a handler that does not re-stream makes the node
      # *absent* rather than *stale*, and the test cannot tell those two failure modes apart.
      broadcast({:city_grew, CityMap.new(6, 6)})
      broadcast({:city_node_placed, Node.new(1, 1, :park)})
      assert rendered_node(render(view), "1:1") =~ "width: 128px"

      eight = %{CityMap.put_node(CityMap.new(6, 6), Node.new(1, 1, :park)) | width: 8, height: 8}
      broadcast({:city_grew, eight})

      html = rendered_node(render(view), "1:1")
      assert html =~ "width: 96px"
      assert html =~ "left: 96px"
      refute html =~ "128px"
    end

    test "the background grid and the banner follow too", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      broadcast({:city_grew, CityMap.new(4, 4)})

      # 16 cells, so :grid_cells was recomputed and not merely :width reassigned.
      assert cell_count(render(view)) == 16
      assert has_element?(view, ~s{[style*="width: 512px; height: 512px;"]})
    end

    @tag :stalled_city
    test "the collapse banner is as wide as the grown grid", %{conn: conn} do
      # A 40x30 stalled city (cell 24, banner 960px) broadcast straight to 8x8. Correct code
      # gives 8 * 96 = 768; a mutant that reassigns :width without :cell_size keeps cell 24
      # and gives 8 * 24 = 192. Separated either way -- but note the mutant's figure is 192,
      # not 1024: there is no 6x6 step here, so :cell_size never held 128.
      {:ok, view, _html} = live(conn, ~p"/")

      broadcast({:city_grew, %{CityMap.new(8, 8) | nodes: stalled_city(0.0).nodes}})

      assert has_element?(view, ~s{#collapse-banner[style*="width: 768px"]})
    end

    @tag :stalled_tiny_city
    test "the collapse banner is as wide as the starting grid", %{conn: conn} do
      # Pins spec section 3's measured relationship at the smallest grid the game renders:
      # 2 * 128 = 256px, which is what the `:locked` headline's 245px two-line threshold
      # bought. If this reads 192px, someone set @max_cell back to 96.
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, ~s{#collapse-banner[style*="width: 256px"]})
    end

    test "a reset takes the grid back to 2x2", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      broadcast({:city_grew, CityMap.new(12, 12)})
      assert has_element?(view, ~s{[style*="width: 768px; height: 768px;"]})

      broadcast({:city_reset, CityMap.new()})

      # 2 * 128. Before this change the reset handler cleared the stream and left the grid
      # assigns alone, which was correct only while a reset preserved its grid.
      assert has_element?(view, ~s{[style*="width: 256px; height: 256px;"]})
      assert cell_count(render(view)) == 4
    end
  end

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(ArmchairMetropolist.PubSub, @topic, message)
  end

  # How many background cells the grid rendered. A plain regex over the markup rather than
  # a DOM query: this project has no Floki dependency (LiveView 1.2 uses `lazy_html`), so
  # `Floki.find/2` would not compile. Background cells are the only elements carrying
  # `phx-click="place"`; a placed node carries `phx-click="demolish"`.
  defp cell_count(html) do
    Regex.scan(~r/phx-click="place"/, html) |> length()
  end
```

`@topic` is already defined at `:30` as `CityEngine.topic(CityEngine.default_city_id())`, and the file's `setup` starts an engine at that id (`:46`) and puts it in the session (`:53`), so every test in this file mounts that one city and the broadcast reaches it. Add `alias ArmchairMetropolistWeb.SimulatorLive` if Task 2 has not already.

The `:stalled_tiny_city` tag needs a new `initial_snapshot/1` clause. **Insert it among the
existing clauses, not after them** — the file carries a comment explaining that the
compiler warns when a function's clauses are not grouped, and `mix test` prints it on every
run:

```elixir
  # `@tag :stalled_tiny_city` seeds the stalled city on the starting 2x2 grid, so the
  # banner's width can be pinned at the smallest grid the game ever renders. Three dead
  # residential blocks draw 45 power against the free baseline of 40, so they starve at zero
  # health and stay there.
  #
  # Seeded through `put_node/2` rather than placed, deliberately: three nodes on a 2x2 is
  # over the growth threshold, so a city built by placing them would arrive as a 4x4 and
  # render at 512px, and this test would pin the wrong number while still passing.
  defp initial_snapshot(%{stalled_tiny_city: true}) do
    city =
      Enum.reduce([{0, 0}, {1, 0}, {0, 1}], CityMap.new(), fn {x, y}, map ->
        CityMap.put_node(map, %Node{
          Node.new(x, y, :residential)
          | health: 0.0,
            status: :offline
        })
      end)

    {:ok, {0, %{city | money: 0.0}}}
  end
```

- [ ] **Step 2: Run the tests to verify they fail — and note *how***

Run: `mix test test/armchair_metropolist_web/live/simulator_live_test.exs`

Expected: FAIL with `FunctionClauseError` in `SimulatorLive.handle_info/2`. There is no
clause for `{:city_grew, …}` and **no catch-all**, so the view is killed by the first
broadcast and the following `render(view)` raises too.

This is *not yet* the failure that matters. The stale-geometry bug is invisible while the
view is crashing, so the next step is deliberately split in two.

- [ ] **Step 3: Add the handler WITHOUT `reset: true`, and watch the real failure**

Add the growth clause with only the grid assigns — no re-stream:

```elixir
  def handle_info({:city_grew, city_map}, socket) do
    {:noreply, assign_grid(socket, city_map)}
  end
```

Run: `mix test test/armchair_metropolist_web/live/simulator_live_test.exs`

Expected: the crashes are gone, and **"an existing node's geometry follows the new cell size"
now fails on `width: 96px`** — the rendered node still reads `width: 128px`. Read the failure
message and confirm that is what it says.

**Do not skip this step or fold it into the next.** This failure is the only empirical
evidence that a LiveView stream does not re-render existing entries when an assign changes.
Every other justification for `reset: true` is inference from `LiveStream`'s `Enumerable`
impl. If this test *passes* here, that inference is wrong — stop and re-read
`deps/phoenix_live_view/lib/phoenix_live_view/live_stream.ex:94-114` before writing anything
else, because the rest of this task rests on it.

- [ ] **Step 4: Implement**

Replace `handle_info(:city_reset, …)` at `:171-173` and add the growth clause beside the other `handle_info`s:

```elixir
  # Carries the whole map, and re-streams every node rather than patching. Nothing is
  # re-keyed by a growth — the origin does not move, so every node keeps its id — but
  # cell size shrinks as the grid grows, and a LiveView stream does not re-render existing
  # entries when an assign changes. Without `reset: true` the nodes keep the pixel
  # geometry they were first rendered with: from 6x6 -> 8x8 that is 128px boxes on a 96px
  # grid.
  #
  # Unconditional, not "only when cell size actually moved". That condition is true at
  # every growth from 6x6 upward, and getting it wrong is silent.
  def handle_info({:city_grew, city_map}, socket) do
    {:noreply,
     socket
     |> assign_grid(city_map)
     |> stream(:nodes, CityMap.nodes(city_map), reset: true)}
  end

  def handle_info({:city_reset, city_map}, socket) do
    # The grid resizes too: a reset returns the city to a 2x2 whatever it had grown to.
    {:noreply,
     socket
     |> assign_grid(city_map)
     |> stream(:nodes, [], reset: true)}
  end
```

Then drop the reply-side stream mutations. In `handle_event("place", …)`:

```elixir
    case CityEngine.place(socket.assigns.city_id, x, y, type) do
      {:ok, _node} ->
        # No `stream_insert` here. The engine broadcasts `{:city_node_placed, node}` on
        # every successful placement and this view is subscribed to it, so inserting from
        # the reply as well did the same work twice. Demolish is the same shape below.
        {:noreply, socket}
```

and in `handle_event("demolish", …)`:

```elixir
    case CityEngine.demolish(socket.assigns.city_id, x, y) do
      {:ok, _id} ->
        {:noreply, socket}
```

Finally rewrite the moduledoc at `:1-23`. Two claims are now false — "a 40x30 grid" and the never-re-diffed rationale:

```elixir
  @moduledoc """
  The city dashboard: a growing grid, live infrastructure, and live metrics.

  ## Rendering strategy

  The background grid is a plain comprehension over `@grid_cells`, so it re-renders
  whenever the grid's dimensions change and is otherwise untouched — nothing in a tick
  changes `@grid_cells`. Placed infrastructure is tracked separately in
  `stream(:nodes, ...)`, keyed by the node's own `"x:y"` id via `dom_id: & &1.id`. Every
  tick only touches the handful of nodes that actually changed, so only those stream
  entries are patched. Nodes are absolutely positioned over the grid so the two layers
  stay independent.

  **A growth is the exception, and it re-streams every node.** Growth is anchored at the
  origin, so no id changes — but cell size shrinks as the grid grows, and a LiveView
  stream does not re-render existing entries when an assign changes. `{:city_grew, ...}`
  therefore passes `reset: true`; see `handle_info/2`.

  ## Where the figures come from

  `CityEngine.snapshot/1` returns full resource statistics at mount, before any tick —
  it computes them through `UseCases.SummarizeCity`, since `Infrastructure` may not
  reach `Domain.Services`. The engine also broadcasts `{:city_metrics, …}` after every
  successful place and demolish, so the legend's counts move on the click rather than
  on the next tick.
  """
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/armchair_metropolist_web/live/simulator_live_test.exs`
Expected: PASS, including the pre-existing wipe/reset tests Task 4 broke — but only after the fix in Step 6 below. If "another viewer's reset clears this one's grid too" still fails, that is Step 6, not a defect here.

- [ ] **Step 6: Fix the test that broadcasts the bare atom**

`simulator_live_test.exs:1263-1275` ("another viewer's reset clears this one's grid too")
broadcasts `:city_reset` directly on `@topic` at `:1272`, bypassing the engine entirely, so
Task 4's change to the engine did not touch it and deleting the bare-atom clause breaks it:

```elixir
      Phoenix.PubSub.broadcast(ArmchairMetropolist.PubSub, @topic, {:city_reset, CityMap.new()})
```

While there, extend it: the test asserts the node is gone, and it should now also assert the
grid resized, which is the behaviour this task adds.

```elixir
      assert has_element?(view, ~s{[style*="width: 256px; height: 256px;"]})
```

- [ ] **Step 7: Run the whole suite**

Run: `mix test`
Expected: PASS. This is the first green suite since Task 3.

- [ ] **Step 8: Commit Tasks 4 and 5 together**

```bash
git add lib/armchair_metropolist_web/live/simulator_live.ex test/armchair_metropolist_web/live/simulator_live_test.exs lib/armchair_metropolist/infrastructure/simulation/city_engine.ex test/armchair_metropolist/infrastructure/simulation/city_engine_test.exs
mix precommit
git commit -m "feat: resize the view when the grid grows or resets

{:city_grew, map} re-streams every node with reset: true. Anchored growth
re-keys nothing, but cell size shrinks as the grid grows and a LiveView stream
does not re-render existing entries on an assign change -- from 6x6 to 8x8
that left 128px nodes on a 96px grid.

:city_reset becomes {:city_reset, map} so the handler can resize; it previously
cleared the stream and left the grid assigns alone, which was correct only
while a reset preserved its grid.

Also drops the reply-side stream_insert and stream_delete_by_dom_id, which
duplicated the broadcasts the same click already produces.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: Start new cities at 2×2, and migrate the tests that assumed 40×30

The breaking change, isolated to one commit.

**Files:**
- Modify: `lib/armchair_metropolist/infrastructure/simulation/city_engine.ex:102-103` (delete both attributes), `:467-472` (`new_city_map/0`)
- Modify: `config/config.exs:49-50` (delete both keys)
- Modify: `test/armchair_metropolist/infrastructure/simulation/city_engine_test.exs`
- Modify: `test/armchair_metropolist_web/live/simulator_live_test.exs`

**Interfaces:**
- Consumes: `CityMap.new/0` from Task 1.
- Produces: nothing.

- [ ] **Step 1: Write the failing test**

```elixir
  test "a brand new city starts on the 2x2 grid", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, ~s{[style*="width: 256px; height: 256px;"]})
    assert cell_count(render(view)) == 4
  end
```

Put it in `simulator_live_test.exs` as an **untagged** test, so it exercises the real
`{:error, :not_found}` → fresh-city path.

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test test/armchair_metropolist_web/live/simulator_live_test.exs`
Expected: FAIL — the grid is 960×720, because `new_city_map/0` still reads the config.

- [ ] **Step 3: Implement the flip**

In `city_engine.ex`, delete `@default_grid_width` and `@default_grid_height` at `:102-103`, and replace `new_city_map/0`:

```elixir
  # `CityMap.new/0` rather than config values. The starting grid is a domain decision --
  # growth, the cap and the starting size are one rule, stated once in `CityMap` -- and a
  # config key here would be a second place to state it. That is the drift the
  # `@opening_grant` comment in `city_map.ex` was written about.
  defp new_city_map, do: CityMap.new()
```

In `config/config.exs`, delete the `grid_width: 40,` and `grid_height: 30,` lines.

- [ ] **Step 4: Find every affected test, with a recipe that actually finds them**

Run: `mix test` and read the failures — but do **not** rely on the failure list alone, and do
not rely on a naive grep. Coordinates reach the code three ways in this suite, and only the
first is greppable as a literal:

1. literal attributes — `phx-value-x="9"`, `"x" => "3"`, `place(city_id, 3, 4, …)`
2. **the `place(view, type, x, y)` helper** at `simulator_live_test.exs:1199-1207`, which
   interpolates `phx-value-x="#{x}"` — invisible to any search for a digit
3. **interpolated loops** — `for x <- 1..4`, and the `phx-value-x="#{x}"` selectors at
   `:510` and `:1039`

And seeding is invisible too: `StubSnapshotRepository`'s **default is already
`{:error, :not_found}`** (`test/support/stub_snapshot_repository.ex:14`), so a describe that
never calls `set_initial/1` still hydrates a fresh city. `rg 'not_found'` will not find it.

```bash
# every call through the helper, with its coordinates
rg -n 'place\(view, ' test/
# every literal coordinate reaching a command
rg -n 'phx-value-x="[0-9]"|"x" => "[0-9]"|place\(city_id, [0-9]+, [0-9]+' test/
# every describe that seeds a fresh city, INCLUDING by omission
rg -n 'set_initial|describe ' test/armchair_metropolist/infrastructure/simulation/city_engine_test.exs
# tests that assert the old default grid literally
rg -n 'width == 40|height == 30|new\(40, 30\)' test/
```

- [ ] **Step 5: Migrate, by category**

Three categories, and the category decides the fix. Getting this backwards destroys what a
test covers, so classify before editing.

**(A) Tests whose subject *is* a fresh city — keep untagged, move the coordinate.**
Only viable where the test places at most two nodes, since a third grows a 2×2. Move to
`(1, 1)`, not `(0, 0)`, so the assertion still proves the coordinate was threaded through
rather than defaulting to zero.

| line | change | also update |
|---|---|---|
| `:198` | `%{"x" => "3", "y" => "4"}` → `"1"`/`"1"` | `id="3:4"` → `id="1:1"` at `:201-202` |
| `:241` | same, in the desktop test | **`:248` `assert CityMap.occupied?(desktop_map, 3, 4)` and `:251` `refute CityMap.occupied?(session_map, 3, 4)`** → `1, 1` |
| `:270` | `phx-value-x="2"][phx-value-y="3"` → `"1"`/`"1"` | see below — the assertion is vacuous and must change too |
| `:288` | `phx-value-x="9"][phx-value-y="9"` → `"1"`/`"1"` | `id="9:9"` and the `title=` regex at `:294` |
| `:329`, `:337` | `phx-value-x="7"][phx-value-y="8"` → `"1"`/`"1"` | both `id="7:8"` assertions |
| `:467` | `phx-value-x="3"][phx-value-y="3"` → `"1"`/`"1"` | nothing — it asserts on legend cells |

At `:270`, `assert render(view) =~ "2:3"` **cannot fail**: the background cell itself renders
`title="place power_plant at 2:3"` (`simulator_live.ex:239`), so that substring is present
whether or not the placement succeeded. It is vacuous today. Fix it while migrating:

```elixir
      assert render(view) =~ ~s{id="1:1"}
```

**(B) Tests whose subject is grid-size-independent and which place more than a 2×2 holds —
give them a roomy seed, do not touch their coordinates.** Add one `initial_snapshot/1`
clause, **inserted among the existing clauses** so the compiler does not warn about ungrouped
clauses:

```elixir
  # `@tag :roomy_city` seeds an explicit 40x30 carrying the ordinary opening grant, for tests
  # whose subject has nothing to do with grid size and which place more blocks than a 2x2
  # holds. 40x30 is above the growth cap, so the grid cannot grow underneath them either --
  # which matters, because a growing grid changes the legal coordinate set between clicks.
  defp initial_snapshot(%{roomy_city: true}), do: {:ok, {0, CityMap.new(40, 30)}}
```

Then tag these six, all of which use the `place(view, …)` helper and place 2–7 nodes:

| line | places |
|---|---|
| `:848` | residential `(2,1)`, park `(3,1)` |
| `:865` | residential `(1,1)`–`(3,1)`, park `(1,2)` |
| `:883` | residential `(1,1)`–`(4,1)`, parks `(1,2)`–`(3,2)` — seven nodes |
| `:896` | residential `(2,1)`, parks `(1,2)`, `(2,2)`, `(3,2)` |
| `:910` | parks `(2,1)`, `(3,1)` |
| `:923` | power plant `(2,1)` |

**(C) Tests that assert the old default grid literally — change the assertion, never the
seed.** Reseeding these deletes the fallback behaviour they exist to test:

- `city_engine_test.exs:151-152` — `assert city_map.width == 40` / `== 30` become `== 2`. The
  test is named "falls back to an empty **configured** grid when nothing is stored"; Task 6
  deletes the config, so rename it to "falls back to an empty starting grid when nothing is
  stored".
- `city_engine_test.exs:207-208` — the same pair inside "start_link/1 returns before a slow
  repository has answered". Assertions to `== 2`; the name still holds.

**Engine describes that seed a fresh city and place out of bounds — reseed the describe.**
These test commands and broadcasts, not grid size, so one line beats seven coordinate edits:

```elixir
      # An explicit 40x30 rather than a fresh city: a fresh city is now a 2x2 where (3, 4) is
      # out of bounds. Above the growth cap, so it also never grows under a test that is not
      # about growth.
      StubSnapshotRepository.set_initial({:ok, {0, CityMap.new(40, 30)}})
```

- the "infrastructure commands" describe at `:250-253`, which places at `(3, 4)` seven times
  (`:259`, `:269`, `:272`, `:286`, `:296`, `:306`, `:309`)
- **the "isolation between cities" describe at `:794-826`, which has no `set_initial` at all**
  and rides the stub's default. `:801` and `:818` place at `(3, 4)` and `:822` asserts
  `{:city_node_placed, %Node{x: 3, y: 4}}`.
- `:977`, which places at `(3, 4)`

Leave `:319` (`place(city_id, 40, 0)` expecting `:out_of_bounds`) alone — with a 40×30 seed it
still fails the same bound for the same reason.

Two entries can be skipped, verified safe: `:329`'s `demolish(city_id, 5, 5)` never
bounds-checks (`manage_infrastructure.ex:56-58`), and `:1136`'s `place(city_id, 10, 10, …)` is
seeded by `dead_city/2`, which builds on an explicit `CityMap.new(40, 30)` (`:1374`).

- [ ] **Step 6: Run the whole suite**

Run: `mix test`
Expected: PASS.

- [ ] **Step 7: Confirm the migration did not hide a regression**

A green suite after a fixture change is the weakest evidence there is. Check the count moved the way you expect:

```bash
mix test 2>&1 | tail -3
```

The baseline measured on this branch before Task 1 was **429 passed (6 properties, 423 tests), 0 failures**, plus the two documented migration-redefinition warnings. The total must be **baseline + the tests added in Tasks 1–6**, with zero skipped. If the total is unchanged, a test was silently replaced rather than added.

- [ ] **Step 8: Commit**

```bash
git add lib/armchair_metropolist/infrastructure/simulation/city_engine.ex config/config.exs test/
mix precommit
git commit -m "feat: start new cities on a 2x2 grid

new_city_map/0 becomes CityMap.new/0 and the grid_width/grid_height config
keys are deleted, so the starting size lives only in CityMap.

Migrates the tests that assumed a fresh city was 40x30: the engine's
'infrastructure commands' describe gets an explicit 40x30 seed, since it tests
commands rather than grid size, while the LiveView tests move to (1,1) so they
keep exercising the real fresh-city path.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: Documentation

**Files:**
- Modify: `lib/armchair_metropolist/domain/entities/city_map.ex:77`, `lib/armchair_metropolist/use_cases/reset_city.ex:2`
- Modify: `test/support/playing_guide.ex:169`, `:225`, `:660`
- Modify: `docs/PLAYING.md`

**Interfaces:** none.

- [ ] **Step 1: Fix the two remaining "same grid" docstrings**

Task 1 rewrote `city_map.ex:77`'s body and Task 4 fixed `city_engine.ex:157`. Confirm nothing is left:

```bash
rg -n 'same grid' lib/
```

Expected: only `use_cases/reset_city.ex:2`. Change its moduledoc to:

```elixir
  @moduledoc "Use case: discard a city and start a new one on a fresh starting grid."
```

Re-run the grep; expect no hits.

- [ ] **Step 2: Comment the guide generator's fixed grid**

At `test/support/playing_guide.ex:169`, `:225` and `:660`, `CityMap.new(40, 30)` is now a
deliberate choice rather than the default. Add above the first one:

```elixir
  # An explicit 40x30 and not `CityMap.new/0`. Every figure this module generates is
  # independent of grid size -- the simulation reads no coordinates -- and 40x30 is above
  # the growth cap, so capacity never binds and no measurement here can be perturbed by a
  # grid that grew mid-sequence. Migrating this to `new/0` would change what the guide
  # measures.
```

- [ ] **Step 3: Add the growth passage to the player guide**

In `docs/PLAYING.md`, after the paragraph that introduces placing blocks, add:

```markdown
### The map grows with the city

You start on a 2×2 grid — four cells. Place your third block and two more rows and
columns open up, giving you a 4×4; the twelfth opens a 6×6, and so on up to 32×32. The
grid opens whenever more than 70% of its cells are occupied, so you are never forced to
fill it completely before it gives you room.

New rows and columns appear at the right and bottom edges. Nothing you have already built
moves, and no block changes its coordinates — the map grows away from the corner you
started in, rather than shifting your city around.

The cells themselves shrink as the grid grows, so the whole map stays a comfortable size
on screen rather than running off the edge: it reaches its full width at 6×6 and stays
there.
```

Do **not** state a figure that a generator could produce instead — the growth thresholds
above are structural constants, not measurements, so a literal is correct here.

- [ ] **Step 4: Verify the guide tests still pass**

Run: `mix test test/docs/playing_guide_test.exs`

Expected: PASS. The generated blocks are delimited by `<!-- generated:… -->` markers and
the new prose is outside them, so it cannot affect them. If this fails, the passage landed
inside a generated block — move it.

- [ ] **Step 5: Run the whole suite and commit**

```bash
mix test
git add lib docs test/support/playing_guide.ex
mix precommit
git commit -m "docs: describe grid growth for players and fix stale docstrings

Three docstrings said a reset starts a new city 'on the same grid', which a
2x2 reset falsifies. PLAYING.md gains a passage on growth, and the guide
generator's explicit 40x30 is commented as a deliberate capacity-never-binds
fixture rather than a stale default.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Spec sections with no task, and why

- **§5, the domain capacity guard.** `SimulationCalculator`'s `placements/3` gates on
  `length(nodes) < width * height` and needs **no change** — it stays correct and stays
  reachable, since growth cannot fire at or above the cap. Nothing to implement, and its
  behaviour is already covered by `simulation_calculator_test.exs:1159`, which fills all
  1,200 cells of a 40×30. Verify that test still passes rather than adding a new one.
- **§6's optional `>` vs `>=` test.** Deliberately omitted. The two operators differ on
  exactly one input, and it is an integer only at n ∈ {10, 20, 30}, so pinning it costs a
  70-node fixture to separate implementations that are identical at the other twelve ladder
  sizes. The three threshold tests in Task 1 pin the constant, which is what matters.

## After the plan

Two items the spec records that this plan deliberately does **not** implement:

1. **Spec §4 asks for the legend wrap thresholds to be re-measured** at a 768px and a 256px
   grid, to confirm they are merely conservative rather than wrong. That is a browser
   measurement, not a code change, and it belongs after the feature runs. Do it with the
   dev server and record the binding element.
2. **Spec §10 records a pre-existing defect** — a click composed before a reset can place a
   block into the fresh city. It is on `main`, this branch narrows it from 1,200 reachable
   cells to 4, and fixing it needs its own decision about what a refused click tells the
   player. Track separately.
