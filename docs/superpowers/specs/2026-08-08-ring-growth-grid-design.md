# Growing grid

A new city starts on a 2×2 grid and opens two more rows and columns each time it fills
past 70%, up to a 32×32 cap. Replaces the fixed 40×30 grid every city has started on
until now.

> **Growth is anchored at the origin.** An earlier draft of this design recentred the
> city, adding a cell on all four sides so the city stayed in the middle of the map. That
> is abandoned — see §9 for why, since the reason is not obvious and the abandoned version
> is the one the feature was first described as.

## Why

A 40×30 grid is 1,200 cells. The opening sequence in `docs/PLAYING.md` places seven
blocks. A first-time player therefore meets the game as a wall of empty squares with a
speck in one corner, and nothing on screen suggests where to start or what scale is
intended. Starting at 2×2 and growing makes the map a consequence of the city rather
than a backdrop for it.

## What this cannot affect

**The simulation reads no coordinates.** `Domain.Services.SimulationCalculator` and
`Domain.Entities.SimulationMetrics` never touch `node.x` or `node.y`; coordinates appear
only in `Node.id/2`, `CityMap`'s lookups, and `UseCases.ManageInfrastructure`'s bounds
and occupancy checks. `docs/PLAYING.md` already states this from the player's side —
"flung to opposite edges of the grid produce byte-identical" results.

Two consequences, and both are load-bearing for the rest of this document:

1. Every generated figure in the playing guide is independent of grid size. Growth cannot
   move a health curve, an income figure or an opening deadline.
2. The grid is *capacity plus presentation*, nothing more. There is exactly one place in
   the domain where capacity is read, and it is named in §5.

## 1. The rule

Three attributes on `CityMap`, beside the existing `@opening_grant`:

```elixir
@initial_size 2
@max_size 32
# Numerator and denominator rather than 0.7, so the trigger is integer arithmetic and
# never a float comparison. See §6 for what this does *not* buy.
@fill_numerator 7
@fill_denominator 10
```

* `new/0` → `new(@initial_size, @initial_size)`. `new/2` stays, for stored rectangular
  cities and for fixtures that want a grid large enough that capacity never binds.
* `reset/1` → `new/0`, ignoring the map's current size. A reset city is a new city in
  every respect including its grid, which keeps `reset/1`'s docstring claim — one
  definition of what a new city is — literally true.
* `grow_if_crowded/1` grows the map when **both** hold, and returns it unchanged
  otherwise:
  * `max(width, height) < @max_size`
  * `node_count * @fill_denominator > @fill_numerator * width * height`

`max(width, height)` rather than `width` alone is what protects stored 40×30 cities: 40
exceeds the cap, so they never join the ladder. This is a real case, not a hypothetical —
every city saved before this change is 40×30.

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

This is the property the rest of the design leans on, and it is worth naming because it is
easy to destroy. A coordinate is only a name, and its meaning comes from the grid it
indexes. Because growth adds cells without moving the origin, `(3, 4)` denotes the same
cell before and after, forever. That is what makes it safe for a click — which carries
`phx-value-x` / `phx-value-y` baked into the DOM at render time, not a node identity — to
be interpreted against a grid that has since grown. Anything that moved the origin would
reinterpret coordinates already in flight, and since old and new coordinate sets overlap
those commands would not fail, they would hit **a different cell**. §9 has the case.

**Do not change growth to move the origin without reading §9.**

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
blocks, roughly 9,500 in construction costs at the cheapest rate — far past anything a
player reaches, which is the intent: the cap is a bound on the data structure, not a
game mechanic.

## 2. Where growth is applied

In `UseCases.ManageInfrastructure.place/4`, after a successful `put_node`.

**Not** in `CityMap.put_node/2`. Fixtures call `put_node` directly with hundreds of nodes
— `PlayingGuide.city_with/1` builds cities of arbitrary size that way — and growth there
would change the dimensions those fixtures assume mid-build.

`place/4` keeps its `{:ok, {city_map, node}}` shape.

`CityEngine` detects growth by comparing `city_map.width` against the map it already
holds in its state. No `:grew` flag is threaded through the use case, and the use-case
contract does not change.

```elixir
if city_map.width != state.city_map.width do
  broadcast(state.city_id, {:city_grew, city_map.width, city_map.height})
end
broadcast(state.city_id, {:city_node_placed, node})
broadcast(state.city_id, {:city_metrics, metrics})
```

`{:city_grew, …}` carries only the dimensions. Because no id changed, subscribers need no
node data — the existing stream entries stay valid and the placed node arrives through the
ordinary `{:city_node_placed, …}` that follows. Both messages are sent on a growing
placement, in that order, so a subscriber sizes the grid before the new node lands on it.

It must be a broadcast rather than only a reply: the re-entry code lets a second browser
join the same city, and both viewers must resize.

### Dropping the reply-side `stream_insert`

`handle_event("place", …)` currently does `stream_insert(socket, :nodes, node)` from
`place/4`'s reply, *and* receives `{:city_node_placed, node}` on the broadcast. The insert
is redundant, and idempotent, so nothing today reveals the duplication.

Removing it makes place and demolish symmetrical, both driven entirely by the broadcast.

**This is a de-duplication and nothing more.** The recentring draft justified it by a
rendering glitch — a translated node painting outside its container for one frame — and
with anchored growth that glitch does not exist, because a placed node's coordinates are
inside the old grid whether or not it grew. So this carries no correctness argument, only
tidiness, and it is the one part of this change that alters existing behaviour. It needs
its own test: placing a block still renders it with the reply-side insert gone.

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

`max(width, height)` rather than the width alone, so the bound holds on the longer axis
and a rectangular legacy city cannot exceed the target footprint on its taller side.

Footprint: **256px (2×2) → 512px (4×4) → 768px (6×6)**, then held between 748px and
768px while cells shrink to 24px at the cap. With the 70% rule those three sizes land on
the 3rd, 12th and 26th block placed.

A stored 40×30 city gives `div(768, 40) = 19`, clamped up to `@min_cell` 24, rendering at
960×720 — **pixel-identical to today**. No existing city changes appearance.

`cell_style/3` already takes `cell_size` as a parameter, so it needs no change.

`assign_grid(socket, city_map)` sets `:width`, `:height`, `:cell_size` and `:grid_cells`
in one place, called from `do_mount/3`, from `{:city_grew, …}` **and from `:city_reset`**.
The third is a bug fix: `handle_info(:city_reset, …)` today resets the node stream and
nothing else, which was correct while a reset kept its grid and is wrong the moment
`reset/1` returns a 2×2.

`simulator_live.ex`'s moduledoc claims the background grid "is never re-diffed on its
own, since nothing in a tick ever changes `@grid_cells`". Still true per tick, false
across a placement. It must be rewritten, not left alone. Its opening line — "a 40x30
grid" — is also now wrong.

### Why 128, measured

`@max_cell` is set by the collapse banner, which is styled `width: #{@width *
@cell_size}px` so that it shares the grid's width exactly. The banner is reachable on a
2×2 — a single water plant has a money ceiling of 0 against 5 of upkeep, so it is
insolvent, and all four banner variants can appear at that size.

Measured in the running app (16px body, `ui-sans-serif`, `font-semibold` → 600,
line-height 24px; banner chrome 37px = `px-4` 32 + `border-l-4` 4 + 1px right border,
all inside `box-border`). The widest headline is `:locked` — "City locked — nothing more
can be built or demolished." — at 417px max-content, and it is the binding one at every
line budget:

| `:locked` fits in | banner width | implied cell at 2×2 |
|---|---|---|
| 1 line | 454px | 227 |
| 2 lines | 245px | 123 |
| 3 lines | 193px | 97 |

* **96 is unusable.** It gives a 192px banner against a 193px 3-line threshold — one
  pixel short, so the worst headline wraps to four lines, and a pixel of drift in either
  direction flips it. A wrap threshold is bistable at its boundary; this is the worst
  place to sit.
* **128 gives 256px**, clearing the 2-line threshold with 11px of slack, and divides 768
  exactly so every cell on the ramp is an integer.
* **227 buys one-line headlines** and costs the ramp: 768/4 = 192 < 227, so the
  footprint would go 454px → 768px and stop, with a 2×2 rendered as four 227px tiles.

The explanatory paragraph under the headline is `text-xs` with a 69px min-content, so it
never constrains anything; it wraps to 8 lines at 2×2, 5 at 4×4 and 3 at full size,
which is acceptable for a terminal-state explanation.

**The banner therefore needs no floor.** `width: #{@width * @cell_size}px` stays exactly
as written and the "so the two cannot drift apart" invariant holds unchanged.

## 4. Layout thresholds

The legend's `max-[2010px]` / `max-[1275px]` wrap thresholds were measured against a
960px grid. The new maximum is 768px, 192px narrower, so they are **conservative at every
grid size** — the sidebar now fits beside the grid at windows narrower than the
thresholds permit, and the legend wraps below the grid earlier than it needs to. Nothing
overflows and nothing overlaps.

Leave them. Chasing them means one threshold per grid size and there are sixteen; grid
width is no longer a constant, so there is no single correct value to chase.

But **re-measure before concluding that**, do not assume it. On the negative-polarity
work the binding constraint on this same sidebar turned out to be a prose footnote at
1198px, not the resource matrix at 927px. If prose is the driver here too, grid width was
never setting these thresholds and the paragraph above is describing a change that does
not exist. Measure at 768px and at 256px, at the recorded threshold windows, and record
which element is binding.

## 5. The one domain reader of capacity

`SimulationCalculator`'s `placements/3` gates the insolvency banner's "place a block"
suggestion on `length(nodes) < city_map.width * city_map.height`, so the banner never
names a placement on a grid with nowhere to put it.

This stays correct and stays reachable. A full grid below the cap is unreachable —
`cells > 7/10 · cells` for any non-empty grid, so filling one always triggers growth —
which means the guard's `else` branch fires only at 32×32. It was already effectively
cap-only at 40×30; the change is that the cap is now a real boundary a city can arrive
at rather than a number no city approached.

## 6. Tests

Each with the mutation it kills. Where a mutation is *not* killable, that is stated
rather than papered over.

**Domain — `CityMap`**

Three tests pin the threshold constant, and it takes all three. Each one admits an
interval of thresholds that would pass it, and only the intersection is narrow:

* Growth fires at 3 on a 2×2 and not at 2. Passed by any threshold in **[0.5, 0.75)** —
  so this alone kills 0.75 (needs 4) and 0.8 (needs 4), but not 0.6.
* Growth fires at 12 on a 4×4 and not at 11. Narrows the survivors to
  **[0.6875, 0.75)** — kills 0.6 and 0.65, which fire at 10 and 11.
* Growth fires at 26 on a 6×6 and not at 25. Narrows to **[0.6944, 0.7222)** — kills
  0.69, which fires at 25 and survives both tests above.

Stopping after the 2×2 test would leave a quarter of the threshold range passing, which
is the trap: the smallest fixture is the easiest to write and pins the least.

The rest:

* Growth adds 2 to both dimensions — kills adding 1, and kills growing one axis only.
* **A 2×2 holding nodes at all four corners grows to a 4×4 whose nodes are still at
  `(0,0)`, `(1,0)`, `(0,1)`, `(1,1)` with those exact ids, and `nodes` is unchanged by
  `==`** — kills any reintroduction of translation. This is the anchoring invariant and
  it is the test that stops §9's hazard coming back.
* Growth is refused at 32×32 — kills dropping the cap.
* A **30×40** city with 841 nodes does not grow — kills `width < @max_size` in place of
  `max(width, height) < @max_size`. The fixture has to be 30×40 and not the legacy 40×30
  shape: with width 40 both predicates are already false, so a 40×30 test cannot separate
  them. Only `width < 32 ≤ height` makes the mutant grow where the correct code refuses.
* A 40×30 city with 841 nodes does not grow either — the legacy shape, asserted for its
  own sake, since leaving stored cities alone is the point of the cap check.
* Demolishing a 4×4 down to 3 nodes leaves it 4×4 — kills a shrink path.
* `reset/1` on a 12×12 returns a 2×2 — kills `new(map.width, map.height)`.

**Not killable, and why.** `>` versus `>=` in the trigger differs on exactly one input,
the boundary itself, which is an integer only when `cells` is divisible by 10 — n ∈
{10, 20, 30}. At the other twelve ladder sizes the two operators are behaviourally
identical, so no small fixture can separate them and none should be written pretending
to. If the operator is worth pinning, it takes one test at 10×10 with 70 nodes asserting
no growth, and 71 asserting growth. Integer arithmetic does not change this; it removes
float comparison, which is a different benefit.

**Cell size**

* 2×2 → 128, 4×4 → 128, 6×6 → 128, 8×8 → 96, 32×32 → 24 — kills dropping either clamp.
  The three 128s look redundant and are not: they are the flat top of the ramp, and a
  missing `min` shows up only there.
* 40×30 → 24, and the rendered grid is 960×720 — kills a regression for stored cities,
  and pins the "pixel-identical to today" claim.
* A hypothetical 20×40 → 19 clamped to 24, driven by the **height** — kills
  `div(@target_px, width)` in place of `max(width, height)`.

**Use case and engine**

* `place/4` on a crowded map returns a grown map, and the placed node is present in it —
  kills growing before the put, which would place into the new dimensions and change which
  cell is legal.
* The engine broadcasts `{:city_grew, 4, 4}` **before** `{:city_node_placed, node}` on a
  growing placement — kills the reverse order, which would land a node on an unsized grid.
* No `{:city_grew, …}` on a non-growing placement — kills broadcasting it unconditionally.
* `{:city_metrics, …}` still follows in both cases — kills an early return that skips it.

**LiveView**

* Placing a block still renders it with the reply-side `stream_insert` removed — kills
  removing the broadcast handler instead.
* On growth, `@width` becomes 4 and the rendered grid has 16 cells — kills reassigning
  `:width` without recomputing `:grid_cells`.
* On growth, the already-placed nodes are still rendered, at unchanged ids — kills a
  gratuitous `reset: true` on the stream, which would work but discards the whole point
  of anchoring.
* On growth from 2×2 to 4×4, the collapse banner's width goes 256px → 512px — kills
  recomputing `:width` without `:cell_size`, since 4 × 128 is the same arithmetic either
  way only if `cell_size` also moved.
* On `:city_reset` from a grown city, `@width` is back to 2 — kills leaving that handler
  as it is today, which is the live bug.
* The collapse banner renders at `width: 256px` on a 2×2 — pins the measured relationship
  in §3.

**Regression**

* `PlayingGuide`'s generated opening sequence is byte-identical to its committed output.
  The sequence runs through the real `place/4`, now with growth wired in, on an explicit
  40×30 grid where 7 blocks never trip it. This is asserted, not assumed.

## 7. Documentation

`PlayingGuide` keeps `CityMap.new(40, 30)` throughout, with a comment recording that the
explicit size is a deliberate "capacity never binds" fixture and not a stale default —
otherwise a future reader will helpfully migrate it to `new/0` and change what the guide
measures.

`docs/PLAYING.md` states no grid dimensions anywhere, so there is nothing to correct.
It gains one new passage: the grid grows, the player meets it on their third placement,
and it extends to the right and downwards rather than moving what is already built. The
opening sequence's own table needs no change — one growth occurs during those seven
blocks, since a 4×4 next opens at 12.

`config/config.exs`'s `grid_width: 40, grid_height: 30` and `CityEngine`'s
`@default_grid_width` / `@default_grid_height` are the only config readers, used solely
by `new_city_map/0`. That function becomes `CityMap.new/0` and the four values are
deleted. Keeping them would put the starting size in two places — the exact drift the
`@opening_grant` comment in `city_map.ex` was written to warn about, where a default in
the struct and a literal in `new/2` desynced on a path only cold loads exercised.

## 8. Risks

* **The banner's 256px budget is pinned to the current headline strings.** Rewording
  `:locked` longer than "City locked — nothing more can be built or demolished." can push
  it to three lines with no test failing, because Elixir tests cannot measure text. The
  §6 test on `width: 256px` pins the *banner's* width, not the headline's fit inside it.
  Mitigation is a comment at the headline naming the measured 245px 2-line threshold and
  why it binds. A character-count assertion would fail loudly on a lengthened headline
  and is worth considering, but it is a proxy for width and would not catch a reworded
  headline of equal length using wider words.
* **`grow_if_crowded/1` is only called from `place/4`.** A city that somehow arrives over
  threshold by another route — a hand-edited snapshot, a future bulk-place — will not
  grow until the next placement. Acceptable, and harmless: an over-threshold grid is a
  normal, playable state, not a broken one.
* **The grid grows down as well as right**, so the page gets taller as the city grows —
  256px to 768px over the first three growths. The legend sits beside or below the grid
  depending on window width (§4), so a taller grid can push it further down. Worth a look
  at the 768px maximum, though it is 48px taller than today's 720px and today's layout is
  fine.

## 9. Why growth is anchored and not centred

The feature was first described as opening "a new outer ring", and the first draft of this
design did that literally: a cell on all four sides, so `(0,0)` became `(1,1)` and the
city stayed centred as the map grew around it. It is the better-looking option and it was
abandoned for a correctness reason that is not visible from the description.

Recentring rewrites every node's `x`, `y` and `id`. Clicks carry coordinates baked into
the DOM at render time, so a command issued against a pre-growth DOM is interpreted in the
new coordinate space — and because the old and new coordinate sets **overlap**, such a
command does not fail. It hits a different cell. Concretely: a 2×2 holding nodes at
`(0,0)` and `(1,1)` grows them to `(1,1)` and `(2,2)`; a demolish click on `(1,1)` then
destroys the node that used to be at `(0,0)`. Money spent, wrong block gone, no error.

Two ways in, and the second is what settled it:

* **Same viewer.** Phoenix delivers one connection's events in order to one LiveView
  process and the engine call is synchronous, so a second click has to land in the window
  between the call being issued and the engine broadcasting. Microseconds on a small city
  — but the window contains `summarize/1` over every node, so it widens with city size.
* **Second viewer.** Deterministic and easy to hit. The re-entry code puts two browsers on
  one city. A's placement grows the grid; B's DOM is stale for a full network round trip,
  and every click B makes in that window carries old coordinates.

Fixing it needs the command to carry the grid generation it was composed against, with the
engine refusing a mismatch. Not in the LiveView: its assigns are a replica, and in the
same-viewer case the replica is stale too — payload stale, assigns stale, check passes.
That is roughly forty lines, five tests, and a standing obligation that every *future*
coordinate-addressed command carries the generation, which nothing in the type system
enforces.

Anchoring dissolves all of it. Coordinates never change meaning, so there is nothing to
fence and nothing for a future command to forget. The cost is the visual property: the
city drifts toward the top-left corner instead of staying centred.

**If anyone reinstates centred growth, the fence comes back with it.** The anchoring test
in §6 is what makes that impossible to do quietly.
