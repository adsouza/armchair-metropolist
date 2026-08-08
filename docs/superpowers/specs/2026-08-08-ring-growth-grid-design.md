# Growing grid

A new city starts on a 2×2 grid and opens two more rows and columns each time it fills
past 70%, up to a 32×32 cap. Replaces the fixed 40×30 grid every city has started on
until now.

> **Growth is anchored at the origin.** An earlier draft recentred the city, adding a cell
> on all four sides so the city stayed in the middle of the map. That is abandoned — see
> §9, since the reason is not obvious and the abandoned version is how the feature was
> first described.

## Why

A 40×30 grid is 1,200 cells. The opening sequence in `docs/PLAYING.md` places seven
blocks. A first-time player therefore meets the game as a wall of empty squares with a
speck in one corner, and nothing on screen suggests where to start or what scale is
intended. Starting at 2×2 and growing makes the map a consequence of the city rather
than a backdrop for it.

## What this cannot affect

**The simulation reads no coordinates.** `Domain.Services.SimulationCalculator` and
`Domain.Entities.SimulationMetrics` never touch `node.x` or `node.y`. Verified exhaustive
across `lib/`: `node.x` / `node.y` appear at `city_map.ex:140` and `simulator_live.ex:251`,
`:253`, `:254` and nowhere else; `width` / `height` at `simulation_calculator.ex:333`,
`city_map.ex:88`, `:119` and `simulator_live.ex:81`, `:85`, `:86`, `:437`.

So coordinates are read in exactly two places: the **domain**, for identity and bounds,
and the **LiveView**, for geometry and for the click payload. `docs/PLAYING.md` already
states the simulation half from the player's side — "flung to opposite edges of the grid
produce byte-identical" results.

Two consequences, both load-bearing below:

1. Every generated figure in the playing guide is independent of grid size. Growth cannot
   move a health curve, an income figure or an opening deadline.
2. The grid is *capacity plus presentation*. There is exactly one domain reader of
   capacity (§5) and one presentation reader of geometry (§3).

## 1. The rule

Four attributes on `CityMap`, beside the existing `@opening_grant`:

```elixir
@initial_size 2
@max_size 32
# Numerator and denominator rather than 0.7, so the trigger is integer arithmetic and
# never a float comparison. See §6 for what this does *not* buy.
@fill_numerator 7
@fill_denominator 10
```

**`defstruct` must use `@initial_size`, not a literal:**

```elixir
defstruct width: @initial_size,
          height: @initial_size,
          tick: 0,
          nodes: %{},
          money: @opening_grant,
          waste_stock: 0.0
```

This is not cosmetic. `CityEngine.normalize_city_map/1` merges every decoded snapshot onto
a fresh `%CityMap{}` (`city_engine.ex:463-465`), so the struct defaults are what a stored
city inherits for any field it lacks, and a bare `%CityMap{}` in tests is whatever the
defaults say. Leaving `width: 40, height: 30` there while `@initial_size` is 2 puts the
starting grid in two places — precisely the drift the `@opening_grant` comment at
`city_map.ex:29-33` was written about, where a struct default and a `new/2` literal
desynced on a path only cold loads exercise.

* `new/0` → `new(@initial_size, @initial_size)`.
* `new/2` stays, for fixtures that want a grid large enough that capacity never binds.
  It is **not** how stored cities are rebuilt — those come through
  `normalize_city_map/1` and the struct defaults, never through `new/2`.
* `reset/1` → `new/0`, ignoring the map's current size.
* `grow_if_crowded/1` grows the map when **both** hold, and returns it unchanged
  otherwise:
  * `max(width, height) < @max_size`
  * `node_count * @fill_denominator > @fill_numerator * width * height`

`max(width, height)` rather than `width` alone is **not** what protects stored 40×30
cities — `width < @max_size` already refuses those, since 40 ≥ 32. `max/2` is chosen so
the predicate does not depend on which axis happens to be the larger one; it differs from
`width` alone only for a `width < 32 ≤ height` city, and no such city exists. It is
defensive, not load-bearing, and §6 tests it as such.

Growth is **one-way**. Demolishing below 70% does not take rows away. A shrink path would
have to decide what happens to blocks standing in the rows being removed, and would let
grid size oscillate while a player rearranges.

### Growth is anchored, so nothing is re-keyed

```elixir
defp grow(map), do: %{map | width: map.width + 2, height: map.height + 2}
```

Two rows and two columns appear at the right and bottom edges. **Every existing node keeps
its `x`, `y` and `id`.** The `nodes` map is not rebuilt, not re-keyed, and not touched at
all; growth is a two-field update on the struct.

This is the property the design leans on, and it is worth naming because it is easy to
destroy. A coordinate is only a name, and its meaning comes from the grid it indexes.
Because growth adds cells without moving the origin, `(3, 4)` denotes the same cell before
and after, forever. That is what makes it safe for a click — which carries
`phx-value-x` / `phx-value-y` baked into the DOM at render time, not a node identity — to
be interpreted against a grid that has since grown. Anything that moved the origin would
reinterpret coordinates already in flight, and since old and new coordinate sets overlap
those commands would not fail, they would hit **a different cell**. §9 has the case.

**Do not change growth to move the origin without reading §9.**

Note that anchoring buys *coordinate stability*, not render stability. The rendered
geometry of existing nodes still has to be refreshed on growth, for an unrelated reason —
see §2.

### The ladder

Fifteen growth events, 2→4→…→32. The count is independent of the threshold; the
threshold only sets when each fires.

| n | cells | grows at | n | cells | grows at |
|---|---|---|---|---|---|
| 2 | 4 | 3 | 18 | 324 | 227 |
| 4 | 16 | 12 | 20 | 400 | 281 |
| 6 | 36 | 26 | 22 | 484 | 339 |
| 8 | 64 | 45 | 24 | 576 | 404 |
| 10 | 100 | 71 | 26 | 676 | 474 |
| 12 | 144 | 101 | 28 | 784 | 549 |
| 14 | 196 | 138 | 30 | 900 | 631 |
| 16 | 256 | 180 | 32 | 1024 | — cap |

No size on the ladder has to be completely full to open — the 2×2 grows on its third
block with a cell still free. That is why 70% rather than 80%: at 80% the boundary on a
2×2 is 3.2, so the starter grid alone had to be packed before it would open.

Occupancy immediately after a growth runs from 19% (3 blocks on a fresh 4×4) to 62% (631
on a fresh 32×32), so the grid never presents as cramped. Reaching the cap takes 631
blocks, `631 × 15 = 9,465` in construction costs at the cheapest rate — far past anything
a player reaches, which is the intent: the cap bounds the data structure, not the game.

## 2. Where growth is applied

In `UseCases.ManageInfrastructure.place/4`, **after** the `put_node`, so the predicate
counts the node just placed.

Not in `CityMap.put_node/2`. Two reasons, and the first one is the real one:

1. `put_node/2` is a primitive that sets one key. A growth policy inside it means every
   caller silently gets the policy, including future bulk paths, and there is then no way
   to build a fixture of a given size at all.
2. `test/support/city_generators.ex:20-23` generates grids of 6..12 per side with up to 12
   nodes, which is under threshold at every size it produces (worst case 12 on a 6×6:
   `120 > 252` is false), so nothing breaks today — but that is luck, not design.

For the record, the reason this section previously gave was false: the high-node-count
fixtures (`PlayingGuide.city_with/1` at `playing_guide.ex:660`,
`simulation_calculator_test.exs:1159` filling all 1,200 cells) all build on
`CityMap.new(40, 30)`, where `max(40, 30) ≥ @max_size` refuses growth at any node count.
They were never at risk.

`place/4` keeps its `{:ok, {city_map, node}}` shape.

`CityEngine` detects growth by comparing `city_map.width` against the map it already holds
in its state. No `:grew` flag is threaded through the use case, and the use-case contract
does not change.

```elixir
if city_map.width != state.city_map.width do
  broadcast(state.city_id, {:city_grew, city_map})
end

broadcast(state.city_id, {:city_node_placed, node})
broadcast(state.city_id, {:city_metrics, metrics})
```

`{:city_grew, …}` carries the **whole map**, because the subscriber has to re-stream every
node (below). Both messages are sent on a growing placement, in that order, so a
subscriber sizes the grid before the new node lands on it.

It must be a broadcast rather than only a reply: the re-entry code lets a second browser
join the same city, and both viewers must resize.

`CityEngine`'s moduledoc carries a `## Broadcasts` inventory of every message the engine
sends (`city_engine.ex:36-42`). Adding `{:city_grew, …}` falsifies it, and §7 counts that
as documentation surface.

### Growth must reset the node stream

**Changing `@cell_size` does not re-render existing stream entries, so their geometry goes
stale.** `phoenix_live_view` 1.2.8's `Enumerable` impl for `LiveStream` reduces over
`stream.inserts` only (`deps/phoenix_live_view/lib/phoenix_live_view/live_stream.ex:99-114`),
so a re-render caused by a changed assign iterates an empty insert list and emits nothing.
The client keeps every existing node's inline `left / top / width / height`.

The background grid is a plain `:for` over `@grid_cells` and *does* re-render, so the two
layers diverge:

| growth | cell size | existing nodes |
|---|---|---|
| 2×2 → 4×4 | 128 → 128 | unaffected |
| 4×4 → 6×6 | 128 → 128 | unaffected |
| **6×6 → 8×8** | **128 → 96** | **stale: 128px boxes on a 96px grid** |
| every growth after | shrinks further | stale |

So `{:city_grew, city_map}` must do `stream(socket, :nodes, CityMap.nodes(city_map),
reset: true)` as well as re-assigning the grid. Unconditionally, not only when the cell
size actually moves: conditioning on that is a micro-optimisation whose failure mode is
this exact bug, fifteen times a city.

**This does not reopen §9.** Anchoring's payoff was never rendering — it was that
coordinates keep their meaning, which is what removes the need for a generation fence on
every command. That stands. What anchoring does *not* buy is stable rendered geometry,
because geometry depends on cell size and cell size depends on grid size.

### Dropping the reply-side stream mutations

`handle_event("place", …)` does `stream_insert` from `place/4`'s reply
(`simulator_live.ex:114`) *and* receives `{:city_node_placed, node}` (`:163`), which does
it again. `handle_event("demolish", …)` has the identical duplication:
`stream_delete_by_dom_id` from the reply (`:130`) and again in
`handle_info({:city_node_removed, id}, …)` (`:167-169`). Both are idempotent, so nothing
today reveals either.

**Remove both**, so place and demolish are each driven entirely by the broadcast. An
earlier draft removed only the place-side insert and justified it as making the two
symmetrical; that was false — it would have made them asymmetric, since demolish keeps its
copy.

This carries no correctness argument, only de-duplication, and it is the one part of this
change that alters existing behaviour. The recentring draft justified it by a rendering
glitch; with anchored growth that glitch does not exist. Existing coverage at
`simulator_live_test.exs:198-200` and `:1219` already asserts a placed block renders, so
the risk is covered — no new test is needed for it, and §6 does not add one.

## 3. Cell size

Replaces `@cell_size 24` with three attributes and a function:

```elixir
@min_cell 24
@max_cell 128
@target_px 768

defp cell_size(width, height) do
  min(@max_cell, max(@min_cell, div(@target_px, max(width, height))))
end
```

`max(width, height)` so the bound holds on the longer axis and a rectangular legacy city
cannot exceed the target footprint on its taller side.

Footprints over the ladder: **256px at 2×2, 512px at 4×4, 768px from 6×6 onward**, held
between 748px (22×22, `22 × 34`) and 768px while cells shrink to 24px at the cap. Against
blocks placed, those three footprints arrive at block **0, 3 and 12** — 256px is where a
city starts, 512px comes with the first growth and 768px with the second. The third growth
(block 45, 6×6→8×8) is the first that changes cell size *without* changing the footprint,
which is exactly why it is the transition §2 and §6 care about.

A stored 40×30 city gives `div(768, 40) = 19`, clamped up to `@min_cell` 24, rendering at
`40 × 24 = 960` by `30 × 24 = 720` — **pixel-identical to today** (`simulator_live.ex:230`,
pinned by the existing assertion at `simulator_live_test.exs:1338`).

`cell_style/3` already takes `cell_size` as a parameter (`simulator_live.ex:1023`), so it
needs no change.

### The `assign_grid` seam

```elixir
defp assign_grid(socket, %CityMap{} = city_map)
```

Assigns `:width`, `:height`, `:cell_size` and `:grid_cells`, called from `do_mount/3`,
from `{:city_grew, city_map}` and from `:city_reset`.

**`:city_reset` is currently a bare atom** (`city_engine.ex:323`) and carries no map, so it
cannot call this. Change that broadcast to `{:city_reset, city_map}`, matching
`{:city_grew, city_map}`. The LiveView is the only subscriber, and the engine moduledoc
inventory covers the message shape.

`handle_info(:city_reset, …)` today resets the node stream and nothing else
(`simulator_live.ex:171-173`), which was correct while a reset kept its grid and is wrong
the moment `reset/1` returns a 2×2.

`simulator_live.ex`'s moduledoc claims the background grid "is never re-diffed on its own,
since nothing in a tick ever changes `@grid_cells`". Still true per tick, false across a
placement. Its opening line — "a 40x30 grid" — is also now wrong. Both must be rewritten.

### Why 128, measured

`@max_cell` is set by the collapse banner, which is styled `width: #{@width *
@cell_size}px` so it shares the grid's width exactly (`simulator_live.ex:444-458`). The
banner is reachable on a 2×2 — a water plant has no `money` capacity and 5.0 of `money`
load (`node.ex:66`, `:73`), so one of them is insolvent, and all four banner variants can
appear at that size.

Measured in the running app (16px body, `ui-sans-serif`, `font-semibold` → 600,
line-height 24px; banner chrome 37px = `px-4` 32 + `border-l-4` 4 + 1px right border, all
inside `box-border`). The widest headline is `:locked` — "City locked — nothing more can be
built or demolished." — at 417px max-content, and it binds at every line budget:

| `:locked` fits in | banner width | implied cell at 2×2 |
|---|---|---|
| 1 line | 454px | 227 |
| 2 lines | 245px | 123 |
| 3 lines | 193px | 97 |

* **96 is unusable.** It gives a 192px banner against a 193px 3-line threshold — one pixel
  short, so the worst headline wraps to four lines, and a pixel of drift either way flips
  it. A wrap threshold is bistable at its boundary; this is the worst place to sit.
* **128 gives 256px**, clearing the 2-line threshold with 11px of slack, and divides 768
  exactly so every cell on the ramp is an integer.
* **227 buys one-line headlines** and costs the ramp: `div(768, 4) = 192 < 227`, so the
  footprint would go 454px → 768px and stop, with a 2×2 rendered as four 227px tiles.

The paragraph under the headline is `text-xs` with a 69px min-content, so it never
constrains anything; it wraps to 8 lines at 2×2, 5 at 4×4 and 3 at full size.

**The banner therefore needs no floor.** `width: #{@width * @cell_size}px` stays exactly
as written and the "so the two cannot drift apart" invariant holds unchanged.

## 4. Layout thresholds

The legend's wrap thresholds are `max-[2424px]` expanded and `max-[1415px]` collapsed
(`simulator_live.ex:369`), with the expanded window recorded as `[2343, 2505]`. Both were
measured against a **960px** grid, where the binding element is the totals footnote at
1288px against the nine-column matrix's 927px (`:279-280`, `:345`, `:701`).

*(An earlier draft of this section cited `max-[2010px]` / `max-[1275px]` and a 1198px
footnote. Those are the pre-negative-polarity figures; that reword is what moved them.
Quoted from a stale note rather than read from the code.)*

The new maximum grid is 768px, 192px narrower, so the thresholds are **conservative at
every grid size** — the aside now fits beside the grid at windows up to 192px narrower than
`max-[2424px]` permits, and the legend wraps below it earlier than it needs to. At a 256px
grid the slack is 704px. Nothing overflows and nothing overlaps.

Leave them. Chasing them means one threshold per grid size and there are sixteen; grid
width is no longer a constant, so there is no single correct value.

But **re-measure before accepting that**. The footnote is the binding element at 960px and
it is prose, not the grid — if it stays binding, grid width was never setting these
thresholds and the paragraph above describes a change that does not exist. Measure at
768px and at 256px, at the recorded window, and record which element is binding.

## 5. The one domain reader of capacity

`SimulationCalculator`'s `placements/3` gates the insolvency banner's "place a block"
suggestion on `length(nodes) < city_map.width * city_map.height` (`:333`), so the banner
never names a placement on a grid with nowhere to put it.

This stays correct and stays reachable. A full grid is unreachable *below the cap* —
`cells × 10 > 7 × cells` reduces to `10 > 7` for any non-empty grid, so filling one always
triggers growth. The `else` branch therefore fires exactly where growth cannot help:
**wherever `max(width, height) ≥ @max_size`**, which is 32×32 and also any stored 40×30
that gets filled. (An earlier draft said "only at 32×32", which is false.)

## 6. Tests

Each with the mutation it kills. Where a mutation is *not* killable, that is stated rather
than papered over.

### Threshold constant — three tests, and it takes all three

Each admits an interval of thresholds that would pass it; only the intersection is narrow.

* Fires at 3 on a 2×2, not at 2. Passed by any threshold in **[0.5, 0.75)** — kills 0.75
  (needs 4) and 0.8 (needs 4), spares 0.6.
* Fires at 12 on a 4×4, not at 11. Narrows to **[0.6875, 0.75)** — kills 0.6 and 0.65,
  which fire at 10 and 11.
* Fires at 26 on a 6×6, not at 25. Narrows to **[0.6944, 0.7222)** — kills 0.69, which
  fires at 25 and survives both tests above.

Stopping after the 2×2 test leaves a quarter of the threshold range passing. The smallest
fixture is the easiest to write and pins the least.

**Not killable, and why.** `>` versus `>=` differs on exactly one input, the boundary,
which is an integer only when `cells` is divisible by 10 — and `10 | n²` iff `10 | n`, so
n ∈ {10, 20, 30} of the fifteen growth-capable sizes. At the other twelve the operators are
behaviourally identical; no small fixture separates them and none should pretend to. If the
operator is worth pinning it takes one 10×10 pair: 70 nodes asserting no growth
(`700 > 700` false), 71 asserting growth. Integer arithmetic does not change this — it
removes float comparison, a different benefit.

### Geometry and the cap

* Growth adds 2 to both dimensions. On a 2×2 with 4 nodes (`40 > 28`), a `+1` mutant gives
  3×3 and a one-axis mutant 4×2 — both ≠ 4×4.
* **A 2×2 with nodes at all four corners grows to a 4×4 whose `nodes` map is unchanged by
  `==`, with ids `"0:0"`, `"1:0"`, `"0:1"`, `"1:1"` intact.** This is the anchoring
  invariant and the test that stops §9's hazard returning.
* **Growth is refused at 32×32 holding 717 nodes.** The count matters:
  `n × 10 > 7 × 1024` needs `n ≥ 717`, and a sparsely-filled 32×32 does not grow under
  correct code *or* under a cap-less mutant, so a smaller fixture is vacuous.
* A **30×40** with 841 nodes does not grow — `8410 > 8400` is over threshold, correct code
  refuses on `max(30, 40) ≥ 32`, and the `width < @max_size` mutant sees `30 < 32` and
  grows. This is the only shape that separates that pair; a 40×30 cannot, because `width`
  is already 40.
* A 40×30 with 841 nodes does not grow either — the legacy shape, asserted for its own
  sake, since leaving stored cities alone is the point of the cap check.
* `reset/1` on a 12×12 returns a 2×2 — kills `new(map.width, map.height)`.
* `%CityMap{}.width == 2` and `CityMap.new().width == 2` — kills leaving `defstruct` at 40
  while `@initial_size` is 2, which no other test sees.

**A guard, not a mutation kill:** "demolishing a 4×4 down to 3 nodes leaves it 4×4." No
mutation of the specified implementation can fail this, since `grow_if_crowded/1` is the
only size-changing function and `demolish/3` never calls it. Keep it, labelled as a guard
against a future shrink path, and do not count it as coverage.

### Cell size

* **2×2 → 128 and 4×4 → 128 kill the ceiling clamp.** Dropping `min(@max_cell, …)` gives
  384 and 192. **6×6 → 128 does not**, because `div(768, 6) = 128` exactly — it is as blind
  to the ceiling as 8×8 is. Keep it as a boundary case, not as ceiling coverage.
* **40×30 → 24 and 20×40 → 24 both kill the floor clamp**, since `div(768, 40) = 19` for
  either — `max(20, 40)` is also 40, so the two cases are arithmetically identical on this
  axis. None of the square sizes can: dropping `max(@min_cell, …)` leaves 2×2, 4×4, 6×6,
  8×8 and 32×32 all unchanged.
* 20×40 → 24 *also* kills `div(@target_px, width)` in place of `max(width, height)`, which
  would give 38. That is the mutation it is uniquely for; the floor it shares with 40×30.
* 8×8 → 96 and 32×32 → 24 — the interior of the ramp and its far end.
* The rendered 40×30 grid container is 960×720 — pins "pixel-identical to today".

### Use case and engine

* **`place/4` on a 2×2 holding exactly 2 nodes returns a 4×4 containing all 3 nodes.** The
  count is load-bearing: a grow-*before*-put mutant sees 2 nodes, `20 > 28` is false, and
  does not grow. A fixture already over threshold (2×2 holding 3, placing a 4th) lets the
  mutant grow too and survives. "A crowded map" admits the surviving fixture.
  (The reason an earlier draft gave — that growing first "would change which cell is
  legal" — is false: `in_bounds?` runs in `place/4`'s first `cond` clause,
  `manage_infrastructure.ex:24`, before either operation.)
* **`{:city_grew, …}` arrives before `{:city_node_placed, …}`.** `assert_receive` matches
  against the whole mailbox, so two `assert_receive`s in sequence pass in either order.
  Pin it by receiving once with a catch-all and matching the result:

  ```elixir
  assert_receive first when is_tuple(first)
  assert match?({:city_grew, %CityMap{width: 4}}, first)
  ```

* No `{:city_grew, …}` on a non-growing placement — kills broadcasting it unconditionally.
* `{:city_metrics, …}` still follows in both cases — kills an early return that skips it.

### LiveView

* **After 6×6 → 8×8, an already-placed node's rendered style contains `width: 96px` and
  its `left` is a multiple of 96.** This is the stale-geometry test and it must be observed
  **failing before the fix**, because it is what establishes empirically that stream
  entries do not re-render on an assign change. Written at 2×2 → 4×4 it cannot fail at all:
  cell size is 128 on both sides, so correct and buggy code emit identical geometry.
* On growth, `@width` becomes 4 and the rendered grid has 16 cells — kills reassigning
  `:width` without recomputing `:grid_cells`.
* On growth, previously-placed nodes are still present at unchanged ids — kills a reset
  that drops them.
* **After 6×6 → 8×8 the collapse banner is `width: 768px`.** Not 2×2 → 4×4: cell size is
  128 on both sides there, so correct code gives `4 × 128 = 512` and a mutant that
  reassigns `:width` without `:cell_size` gives the same 512. The test cannot fail. At
  6×6 → 8×8 correct is `8 × 96 = 768` and the mutant is `8 × 128 = 1024`.
* On `{:city_reset, …}` from a grown city, `@width` is back to 2 — kills leaving that
  handler as it is today, which is the live bug.
* The collapse banner renders at `width: 256px` on a 2×2 — pins §3's measured relationship.

### Migrating existing tests

Starting fresh cities at 2×2 breaks every existing test that seeds
`{:error, :not_found}` and then addresses a cell outside a 2×2. Two distinct failure modes:
`CityEngine.place/4` returns `{:error, :out_of_bounds}`, which `handle_event` swallows into
`{:noreply, socket}` so the assertion fails on absent markup; while the
`element(~s{[phx-value-x="9"]…})` form raises *"no element found"*, because the grid only
renders in-bounds cells.

Known sites, to be confirmed by grep rather than trusted from this list:

| file | seeding | coordinates |
|---|---|---|
| `simulator_live_test.exs:160` | untagged fallback `{:error, :not_found}` | `(3,4)` at `:198`, `:241` incl. `id="3:4"` at `:201-202`; `(2,3)` at `:270`; `(9,9)` at `:288`; `(7,8)` at `:329`, `:337`; `(3,3)` at `:467` |
| `city_engine_test.exs:250-253` | `set_initial({:error, :not_found})` for the whole "infrastructure commands" block | `(3,4)` at `:259`, `:269`, `:272`, `:286`, `:296`, `:306`, `:309` |
| `city_engine_test.exs` elsewhere | audit each `set_initial` | `(5,5)` `:329`; `(2,2)` `:385`, `:425`; `(3,4)` `:977`; `(10,10)` `:1136` |

Each affected LiveView test places exactly one node and asserts on its id, so each moves to
`(1,1)` — inside a 2×2, and one node is `10 > 28` false so none trips growth. `(1,1)` rather
than `(0,0)` deliberately, so the assertion still proves the coordinate was threaded through
rather than defaulting to zero.

`city_engine_test.exs:319` asserts `place(city_id, 40, 0)` is `:out_of_bounds` and will keep
passing **for a new reason**. Move it to a coordinate that is out of bounds on a 2×2 but
would have been in bounds on 40×30 only if the intent is unchanged; otherwise leave it and
note why.

Tests that are **safe**, verified not assumed: every tagged fixture seeds an explicit
`CityMap.new(40, 30)`, including the two `simulator_live_test.exs` tests that use
out-of-2×2 coordinates (`:377` tagged `treasury: 24.6`, `:437` tagged `treasury: 1_000.0`)
and the banner-width test at `:1332` tagged `:stalled_city`, whose `40 * 24` still yields
960.

Two tests contradict the new behaviour outright and must be **rewritten**, not extended:

* `city_map_test.exs:68` — `assert CityMap.reset(city) == CityMap.new(40, 30)`, in a test
  named "keeps the grid dimensions and discards everything else".
* `reset_city_test.exs:18` — `assert reset == CityMap.new(40, 30)`.

### Regression

* `PlayingGuide`'s generated opening sequence is byte-identical to its committed output. It
  runs through the real `place/4`, now with growth wired in, on an explicit 40×30 grid where
  7 blocks never trip it. Asserted, not assumed.

## 7. Documentation

Three docstrings say a reset starts a new city **"on the same grid"**, which `reset/1`
returning a 2×2 falsifies. All three change:

* `city_map.ex:77` — `reset/1`'s summary line
* `use_cases/reset_city.ex:2` — moduledoc
* `city_engine.ex:157` — `reset/1`'s `@doc`

Also documentation surface:

* `city_engine.ex:36-42` — the `## Broadcasts` inventory, falsified by `{:city_grew, …}`
  and by `:city_reset` becoming `{:city_reset, city_map}`.
* `simulator_live.ex:3`, `:8-9` — "a 40x30 grid" and the `@grid_cells` never-re-diffed
  claim (§3).

`PlayingGuide` keeps `CityMap.new(40, 30)` at all three sites (`playing_guide.ex:169`,
`:225`, `:660`), with a comment recording that the explicit size is a deliberate "capacity
never binds" fixture and not a stale default — otherwise a future reader helpfully migrates
it to `new/0` and changes what the guide measures.

`docs/PLAYING.md` states no grid dimensions, so there is nothing to correct. It gains one
passage: the grid grows, the player meets it on their third placement, and it extends right
and down rather than moving what is already built. The opening-sequence table needs no
change — one growth occurs during those seven blocks, since a 4×4 next opens at 12.

`config/config.exs:49-50` (`grid_width: 40, grid_height: 30`) and `city_engine.ex:102-103`
(`@default_grid_width` / `@default_grid_height`) are the only config readers, used solely by
`new_city_map/0` (`:467-472`). That function becomes `CityMap.new/0` and all four values are
deleted — with `defstruct` deriving from `@initial_size` (§1), the starting size then lives
in exactly one place.

## 8. Risks

* **The banner's 256px budget is pinned to the current headline strings.** Rewording
  `:locked` longer can push it to three lines with no test failing, because Elixir tests
  cannot measure text. The §6 test on `width: 256px` pins the *banner's* width, not the
  headline's fit inside it. Mitigation is a comment at the headline naming the measured
  245px 2-line threshold. A character-count assertion would catch lengthening but not a
  reword of equal length in wider words.
* **`grow_if_crowded/1` is only called from `place/4`.** A city arriving over threshold by
  another route will not grow until the next placement. Harmless — an over-threshold grid
  is a normal, playable state.
* **The grid grows down as well as right**, so the page gets taller: 256px to 768px over the
  first two growths. Worth a look at the 768px maximum, though it is only 48px taller than
  today's 720px.

## 9. Why growth is anchored and not centred

The feature was first described as opening "a new outer ring", and the first draft did that
literally: a cell on all four sides, so `(0,0)` became `(1,1)` and the city stayed centred.
It is the better-looking option and it was abandoned for a correctness reason invisible from
the description.

Recentring rewrites every node's `x`, `y` and `id`. Clicks carry coordinates baked into the
DOM at render time, so a command composed against a pre-growth DOM is interpreted in the new
coordinate space — and because old and new coordinate sets **overlap**, it does not fail. It
hits a different cell. Concretely: a 2×2 holding nodes at `(0,0)` and `(1,1)` grows them to
`(1,1)` and `(2,2)`; a demolish click on `(1,1)` then destroys the node that was at `(0,0)`.
Money spent, wrong block gone, no error.

**The exposure window is a full client round trip, for one viewer or two.** An earlier draft
claimed the single-viewer case was a microsecond race on mailbox ordering and only the
two-viewer case was deterministic. That was wrong, and it understated the hazard: the growth
broadcast lands in the LiveView's mailbox while `handle_event` is still blocked in
`GenServer.call`, so `handle_info` cannot run and the re-render cannot be pushed until
`handle_event` returns. The browser's DOM therefore carries pre-growth
`phx-value-x` / `phx-value-y` for a full server→client round trip *after* the growth, and
every click in that interval carries stale coordinates. Mailbox ordering was never the
mechanism; DOM staleness is, and it is the same window in both cases.

Fixing it needs the command to carry the grid generation it was composed against, with the
engine refusing a mismatch — not the LiveView, whose assigns are a replica that is stale in
the same window. Roughly forty lines, five tests, and a standing obligation that every
*future* coordinate-addressed command carries the generation, which nothing in the type
system enforces.

Anchoring dissolves all of it. Coordinates never change meaning, so there is nothing to
fence and nothing for a future command to forget. The cost is the visual property: the city
drifts toward the top-left instead of staying centred.

**If anyone reinstates centred growth, the fence comes back with it.** The anchoring test in
§6 is what makes that impossible to do quietly.

## 10. Out of scope: stale commands across a reset

A pre-existing defect, recorded here because reviewing this design surfaced it and the next
reader will otherwise rediscover it.

`reset/1` replaces the city wholesale. A click composed against the pre-reset DOM can still
arrive afterwards, and coordinate stability does not help — the *city* changed, not the
coordinate system. A stale **place** succeeds against the fresh city, spending its grant on a
block the player did not ask for. A stale **demolish** hits an empty cell and is refused
`:empty`, so only placement does damage.

**This is on `main` today and this branch does not cause it.** `main`'s `reset/1` is
`new(map.width, map.height)` (`city_map.ex:88`), keeping 40×30, so any in-bounds stale click
lands. The branch *narrows* it: a reset now returns a 2×2, so a stale click at any coordinate
≥ 2 is refused `:out_of_bounds`, cutting the reachable surface from 1,200 cells to 4.

Not fixed here. It needs its own decision about what a refused click tells the player, and
folding it in would be the second time this feature absorbed unrelated scope. It should be
tracked separately.
