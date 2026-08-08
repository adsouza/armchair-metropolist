# Ring-growth grid

A new city starts on a 2×2 grid and opens a new outer ring each time it fills past 70%,
up to a 32×32 cap. Replaces the fixed 40×30 grid every city has started on until now.

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

1. Every generated figure in the playing guide is independent of grid size. Grid growth
   cannot move a health curve, an income figure or an opening deadline.
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
exceeds the cap, so they never join the square ladder and never re-key. This is a real
case, not a hypothetical — every city saved before this change is 40×30.

Growth is **one-way**. Demolishing below 70% does not close a ring. A shrink path would
have to decide what happens to blocks standing in the ring being closed, and would let
grid size oscillate while a player rearranges.

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

### Recentring

A ring adds one cell on all four sides, so the old origin moves: a node at `(0,0)`
becomes `(1,1)`. Every node's `x`, `y` **and `id`** change, and `id` is both the key in
`CityMap.nodes` and the LiveView stream's `dom_id`.

`Node.translate(node, dx, dy)` performs the shift and rebuilds the id through
`Node.id/2`, so `id` cannot desync from the coordinates it encodes. `CityMap.grow/1`
rebuilds the `nodes` map from the translated nodes; it must rebuild rather than update in
place, because the old and new key sets overlap and an in-place update can overwrite a
node that has not moved yet.

## 2. Where growth is applied

In `UseCases.ManageInfrastructure.place/4`, after a successful `put_node`.

**Not** in `CityMap.put_node/2`. Fixtures call `put_node` directly with hundreds of nodes
— `PlayingGuide.city_with/1` builds cities of arbitrary size that way — and growth there
would re-key them mid-build and change every id those fixtures assume.

`place/4` keeps its `{:ok, {city_map, node}}` shape. Both values are post-growth, so the
returned node is already translated and no caller can hold a stale id.

`CityEngine` detects growth by comparing `city_map.width` against the map it already
holds in its state. No `:grew` flag is threaded through the use case, and the use-case
contract does not change.

```elixir
if city_map.width != state.city_map.width do
  broadcast(state.city_id, {:city_grew, city_map})
else
  broadcast(state.city_id, {:city_node_placed, node})
end
broadcast(state.city_id, {:city_metrics, metrics})
```

`{:city_grew, …}` carries the whole map. Every node id changed, so there is no
incremental patch to send. It must be a broadcast rather than only a reply, because the
re-entry code lets a second browser join the same city and both viewers must resize.

### Dropping the reply-side `stream_insert`

`handle_event("place", …)` currently does `stream_insert(socket, :nodes, node)` from
`place/4`'s reply, *and* receives `{:city_node_placed, node}` on the broadcast — the
insert is already redundant, and idempotent, so nothing today reveals the duplication.

Leaving it in breaks on the growth click. `handle_event` returns and renders before the
broadcast is handled, so there is one frame where the translated node is positioned at
`(2,2)` on a grid still sized 2×2 — outside its own container. Removing it makes place
and demolish symmetrical, both driven entirely by the broadcast, and removes the frame.

This is the one part of this change that alters existing behaviour, so it needs its own
test: placing a block still renders it, with the reply-side insert gone.

### The coordinate-space fence

Clicks carry coordinates, not identities — `phx-value-x={x}` / `phx-value-y={y}` on the
grid cell, and `phx-value-x={node.x}` / `phx-value-y={node.y}` on the node — baked into
the DOM at render time. Recentring reinterprets those coordinates, so **a command issued
against a pre-growth DOM addresses the wrong cell**, and because the old and new key sets
overlap it does not merely fail. On a 2×2 holding nodes at `(0,0)` and `(1,1)`, growth
moves them to `(1,1)` and `(2,2)`; a demolish click on `(1,1)` then destroys the node that
used to be at `(0,0)`. Money is spent, the wrong block is gone, and no error is raised.

Two ways in, and they need separating because only one is a narrow race:

* **Same viewer.** Phoenix delivers one connection's events in order to one LiveView
  process, and the engine call is synchronous, so a second click can only overtake the
  growth broadcast if it lands in the window between the call being issued and the engine
  broadcasting. That is microseconds on a small city — but the window contains
  `summarize/1` over every node, so it *widens with city size*, and the later growths are
  the ones with hundreds of nodes.
* **Second viewer.** Deterministic and easy to hit. The re-entry code puts two browsers on
  one city. A's placement grows the grid; B's DOM is stale for a full network round trip,
  and every click B makes in that window carries old coordinates.

**The fence goes in `CityEngine`, not the LiveView.** Both mutating commands carry the
grid width the DOM was rendered at, and the engine refuses the command unless it matches
`state.city_map.width`:

```elixir
def handle_call({:place, x, y, type, grid_width}, _from, state) do
  if grid_width != state.city_map.width do
    {:reply, {:error, :stale_grid}, state}
  else
    # … as before
  end
end
```

`width` is a sufficient generation token without adding a persisted field: growth is
one-way and monotone, and coordinate meaning is a total function of it. Adding a
`grid_generation` field would mean a `SnapshotVocabulary.modernize/1` entry, a
`normalize_city_map/1` default and committed old-vocabulary fixtures — real cost for no
extra safety on this hazard.

The fence must not live in the LiveView, and the reason is specific rather than a
generality about clients. A LiveView is a server process, so a check against its own
assigns *is* server-side — but it is a check against a replica, and the replica is stale
in exactly the case that matters. In the second-viewer case that LiveView's assigns are
fresh while its browser's DOM is stale, so the check would work. In the same-viewer case
the LiveView has not processed the growth broadcast either: payload stale, assigns stale,
check passes, bug survives. Only the process that owns the map can arbitrate.

**Reject rather than translate.** The offset is exactly `+1, +1`, so the engine *could*
compute what the player "meant" and place there. That guesses which of two things the
click aimed at — the logical cell or the screen position — and after a recentring those
are different cells, because the ring is added around the outside and every pixel now
shows a different coordinate. The LiveView ignores `{:error, :stale_grid}` silently: the
growth broadcast is already in flight and will resynchronise the view, so a flash message
would explain a discarded click the player has no way to act on.

**Accepted limitation.** A reset from a 2×2 to a 2×2 has matching widths, so a click that
crosses it is accepted and places a block in the new city at the coordinate clicked. That
is the right cell, in an unintended city, for 15. Every reset from a grown city is fenced,
since the width differs. Closing the 2×2 case is what a dedicated monotonic counter would
buy, and it is not worth a snapshot migration.

**This hazard is the price of recentring**, and it did not exist before this change: a
fixed grid was the only thing making a coordinate a stable global name, and nothing in the
code recorded that it was doing that job. An anchored, append-only growth has no
re-keying, no overlap and no fence. See §9.

## 3. Cell size

Replaces `@cell_size 24` with three attributes and a function:

```elixir
@min_cell 24
@max_cell 128
@target_px 768

defp cell_size(n), do: min(@max_cell, max(@min_cell, div(@target_px, n)))
```

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
across a placement. It must be rewritten, not left alone.

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
* A node at `(0,0)` is at `(1,1)` with id `"1:1"` after growth, and `"0:0"` is absent
  from `nodes` — kills translating `x` but not `y`, and kills updating `x`/`y` without
  rebuilding `id`.
* A 2×2 holding nodes at all four corners grows to a 4×4 whose four nodes are the inner
  2×2, with no node lost — kills an in-place key update that overwrites an unmoved node.
* Growth is refused at 32×32 — kills dropping the cap.
* A **30×40** city with 841 nodes does not grow — kills `width < @max_size` in place of
  `max(width, height) < @max_size`. The fixture has to be 30×40 and not the legacy 40×30
  shape: with width 40 both predicates are already false, so a 40×30 test cannot separate
  them. Only `width < 32 ≤ height` makes the mutant grow where the correct code refuses.
* A 40×30 city with 841 nodes does not grow either — the legacy shape, asserted for its
  own sake, since not re-keying stored cities is the point of the cap check.
* Demolishing a 4×4 down to 3 nodes leaves it 4×4 — kills a shrink path.
* `reset/1` on a 12×12 returns a 2×2 — kills `new(map.width, map.height)`.

**Not killable, and why.** `>` versus `>=` in the trigger differs on exactly one input,
the boundary itself, which is an integer only when `cells` is divisible by 10 — n ∈
{10, 20, 30}. At the other twelve ladder sizes the two operators are behaviourally
identical, so no small fixture can separate them and none should be written pretending
to. If the operator is worth pinning, it takes one test at 10×10 with 70 nodes asserting
no growth, and 71 asserting growth. Integer arithmetic does not change this; it removes
float comparison, which is a different benefit.

**Use case and engine**

* `place/4` returns a translated node whose id matches its position in the grown map's
  `nodes` — kills returning the pre-growth node.
* The engine broadcasts `{:city_grew, map}` on the growing placement and
  `{:city_node_placed, node}` otherwise — kills broadcasting both, or neither.
* `{:city_metrics, …}` still follows in both branches — kills an early return that skips
  it.

**The coordinate-space fence.** These assert on *state*, not on the return value. A test
that only checks `{:error, :stale_grid}` came back passes against a fence that returns the
error after mutating, so each of these reads the node set afterwards.

* Given a 2×2 with nodes at `(0,0)` and `(1,1)`, grow it, then demolish at `(1,1)` with
  `grid_width: 2`. Assert **both nodes are still present** — kills the unfenced code, which
  destroys the node translated from `(0,0)`. This is the wrong-block case and it is the one
  test that must exist; a stale coordinate landing on an *empty* cell fails anyway and
  proves nothing, so a fixture with only one node cannot discriminate.
* Same setup, place at `(1,1)` with `grid_width: 2`. Assert the node count is unchanged and
  `money` is unchanged — kills a fence that refuses the placement after debiting.
* A command carrying the current width succeeds — kills a fence that rejects everything,
  which every test above would otherwise pass.
* A command carrying a width *greater* than current is refused too — kills `<` in place of
  `!=`. Not reachable in the app, since growth is one-way, but the comparison should not
  encode an assumption the fence does not need.
* The LiveView renders no flash on `{:error, :stale_grid}` — kills surfacing a discarded
  click the player cannot act on.

**LiveView**

* Placing a block renders it with the reply-side `stream_insert` removed — kills removing
  the broadcast handler instead.
* On growth, `@width` becomes 4 and the rendered grid has 16 cells — kills reassigning
  `:width` without recomputing `:grid_cells`.
* On growth, the node layer renders the translated ids and not the old ones — kills
  omitting `reset: true` on the stream.
* On `:city_reset` from a grown city, `@width` is back to 2 — kills leaving that handler
  as it is today, which is the live bug.
* The collapse banner renders at `width: 256px` on a 2×2 — kills decoupling the banner
  from the grid width, and pins the measured relationship in §3.

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
It gains one new passage: ring growth is a mechanic the player meets on their third
placement, and the guide should say what happens and that the city recentres. The
opening sequence's own table needs no change — one growth occurs during those seven
blocks either way, since a 4×4 next opens at 12.

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
* **Re-keying is O(nodes) per growth**, fifteen times over a city's life, at most 631
  nodes on the last one. Negligible, but it is a full stream reset in the LiveView, so
  the growth click repaints the whole node layer. Expected and correct — every id
  changed.
* **`grow_if_crowded/1` is only called from `place/4`.** A city that somehow arrives over
  threshold by another route — a hand-edited snapshot, a future bulk-place — will not
  grow until the next placement. Acceptable; growth on load would mean re-keying during
  hydration, and no such route exists today.
* **Every future coordinate-addressed command inherits the fence requirement.** The fence
  is a rule about the command path, not a property of `place`/`demolish`, and nothing in
  the type system enforces it. A later feature that takes an `x, y` — bulldoze a region,
  drag to place, an undo — is wrong by default until it carries the width.

## 9. The recentring decision, reopened

Recentring was chosen over anchoring at top-left early in the design, on the stated
grounds that anchoring "is not really a ring" while a stable-coordinate variant was "more
machinery than either option". §2's fence is the bill for that, and it was not in the
estimate:

| | recentre | anchor top-left |
|---|---|---|
| node ids on growth | all rewritten | unchanged |
| in-flight commands | old and new key sets overlap, so a stale click hits the **wrong** node | coordinates never change meaning |
| generation fence | required on every coordinate-addressed command, now and in future | not required |
| LiveView on growth | full stream reset | grid assigns only |
| city position | stays centred | drifts toward the top-left |

Anchoring dissolves §2's entire fence section, its five tests, and the standing obligation
on future commands. What it costs is the visual property that motivated the feature: the
city stays put as the map grows around it, instead of the map growing away from it.

**This is a decision to retake, not something to settle here.** The comparison that chose
recentring priced it as "rebuild a map, re-render a stream" and the real price is a
concurrency invariant. Recentring remains defensible — the fence is about forty lines and
five tests, the hazard is fully understood, and the visual payoff is the whole point of the
change. But it should be chosen against an honest bill.
