# Collapse end state and city reset: the sim stops, and the slate can be wiped — design

**Date:** 2026-08-06
**Status:** designed, not yet implemented
**Discharges:** the reset control recommended by the construction-costs design, §8 — "the evidence
for promoting the reset control from a deferred idea to a real requirement is stronger than when it
was deferred […] whoever implements this should read that as a recommendation rather than a note."
That spec also said the item would go in `docs/superpowers/2026-07-30-follow-ups.md`; it never did.
This design supersedes the entry rather than adding it.

## 1. Problem

Two gaps, and they are the same gap seen from either end.

**The simulation never stops.** A fully collapsed city — every node at health 0.0, every node
starving — is a fixpoint in everything that matters: production is health-scaled and therefore zero,
consumption is not health-scaled and therefore unchanged, so the next tick recomputes an identical
result. The engine goes on doing that once a second forever, and nothing on screen says the city is
finished rather than merely unwell.

**A collapsed city cannot be abandoned.** The construction-costs design, §8, records the dead end in
full: `@baseline_capacity` gives money `0.0`, production is health-scaled, so a collapsed city's
`supplied(:money)` is exactly `0.0` and the balance can only hold or drain. Below 10 no demolition is
affordable and below 15 no construction is. A web player can clear the session cookie and get a new
city; **the desktop target has exactly one city, shows no re-entry code, and nothing reaps it, so a
dead city makes the app permanently inert.**

This design adds an end state the engine respects and a control that clears the grid.

### Non-goals

* **No new resource, and no change to any production or consumption table.** Nothing here alters
  what a tick computes; it alters when a tick is run at all.
* **No score, no win condition, no run history.** "Game over" here is a statement about
  reachability, not an outcome being graded.
* **No undo.** The wipe is irreversible by construction — it deletes the stored snapshot (§4).
* **No confirmation dialog.** Decided explicitly during design; see §7.
* **No detection of partial fixpoints.** A live house beside a permanently dead water plant is also
  a fixpoint, and it is deliberately *not* an end state. See §8.
* **No persisted end-state flag.** Both predicates are recomputed from the city on every hydration,
  for the same reason `CityEngine`'s `critical?` seeding is derived rather than stored.

## 2. Three predicates

All three land on `Domain.Entities.SimulationMetrics`, which is already what the view reads and is
already rebuilt every tick. None of them touch `CityMap`, so **no `SnapshotVocabulary` change and no
snapshot migration** — metrics are never persisted.

### `stalled: boolean()`

```elixir
nodes != [] and
  Enum.all?(nodes, &(&1.health == 0.0 and worst_satisfaction(&1, stats) < 1.0))
```

Computed in `Domain.Services.SimulationCalculator` and passed in, not derived inside the entity.
`worst_satisfaction/2` is the rule that decides whether a node regenerates, and it stays in the one
module whose moduledoc documents the tick. A second copy in the entity would be free to drift from
the rule it is meant to mirror.

**Two clauses, and both were measured into existence.**

*The `nodes != []` clause exists because a brand-new city satisfies the naive condition.*
`SimulationMetrics.calculate_avg_health([])` returns `0.0` — the identity of its accumulator, not
"no answer" — so an empty grid reports the same average health as a fully collapsed one. The
companion phrasing "and all nodes are offline" does not rescue it either: with no nodes, all of them
being offline is vacuously true. Measured on a fresh `CityMap.new(40, 30)`:
`{node_count: 0, avg_health: 0.0, offline_count: 0}`. Without this clause the sim would end on
tick 0 of every city.

*The `worst_satisfaction < 1.0` clause exists because a small dead city heals itself.* Consumption is
not health-scaled, so a dead residential block still draws its full 15 power — but the free
`@baseline_capacity` is 40. Two dead houses draw 30 against 40, are fully satisfied, and regenerate
`+1.0` health per tick from an empty treasury. Measured, health after five ticks starting from a
fully dead city:

| dead residential | avg health after 5 ticks |
|---|---|
| 1 | 5.0 |
| 2 | 5.0 |
| 3 | 0.0 |
| 4 | 0.0 |

The cliff is `15n ≤ 40`, i.e. `n ≤ 2`. Ending the sim on health alone would end it one tick before
those cities recover.

**Written per-node rather than over `avg_health`.** Health is clamped non-negative, so
"every node is at exactly 0.0" and "the average is 0.0 over a non-empty set" are the same statement —
but the per-node form has no float sum in it to reason about, and the empty case falls out of
`Enum.all?`'s companion clause instead of needing a guard bolted onto an average.

### `housing_alive: boolean()`

```elixir
Enum.any?(nodes, &(&1.type == :residential and &1.health > 0.0))
```

Computed inside `build/2` from the nodes it already has. No calculator involvement.

`health > 0.0` rather than a status or a count, because this is the reading under which the doom
argument is actually true. Residential is the only type that consumes no labour, so it is the only
source of labour supply; at exactly zero health, labour supply is exactly `0.0` and every other type
starves at the full `@decay_per_tick`. A block at health 5 is `:offline` but still supplies 0.25
labour, and a count-based reading never fires at all on the common death, where the houses are still
standing at zero health.

### `bankrupt: boolean()`

```elixir
city_map.money < Node.cheapest_action_cost()
```

with a new `Node.cheapest_action_cost/0` returning
`min(demolition_cost(), Enum.min(Map.values(@construction_cost_table)))` — **10.0** today.

Derived rather than pinned to `demolition_cost()` directly. `node_test.exs` asserts demolition sits
below the cheapest build, so the two agree now; deriving means a balance patch that inverts them
moves this figure with them instead of silently leaving a threshold naming the wrong lever.

**The threshold is 10, not 0, and that distinction is load-bearing.** Demolishing is a genuine
rescue, because a dead node keeps drawing its full demand and tearing one down is the only way to
reduce demand. Measured: three dead houses and exactly 10 money — demolish one, and the remaining
two are inside the `15n ≤ 40` cliff and heal to 10.0 average health within ten ticks, from a
treasury of 0. A banner at any threshold above 10 would be a false claim.

### `game_over?/1`

```elixir
def game_over?(metrics), do: metrics.stalled and metrics.bankrupt
```

A function on the entity rather than a fourth field, defined once so the template and
`docs/PLAYING.md` cannot disagree about it. `stalled` and `bankrupt` stay separate because they are
independent facts — §6 records two collapses that stall with a full treasury.

### `SimulationMetrics.build/3` gains a key, and its third argument is renamed

The third argument is today `amenity`, carrying three keys. It is already "figures the calculator
computed that the entity cannot", so `stalled` joins it and the parameter becomes `derived`; the
`@default_amenity` constant becomes `@default_derived` with `stalled: false` added. Positional, so
no call site changes. The existing doc comment explaining why a default exists at all — a dozen test
call sites, one production caller that always passes real figures — carries over and is extended.

## 3. Freezing the engine

`CityEngine.handle_info({:tick, _clock_pulse}, state)` gains a leading clause: when
`state.metrics.stalled`, return the state unchanged. No `AdvanceCityTick`, no `{:city_delta, …}`, no
`{:city_metrics, …}`, no checkpoint, no deficit notification.

**Hydration is already correct and needs no change.** `handle_continue(:hydrate, …)` computes
metrics through `summarize/1`, so a stalled city loads stalled and stays frozen — the same reasoning
that makes the `critical?` seeding derived rather than stored. `TickServer` keeps pulsing and the
engine keeps ignoring it, exactly as it already ignores the pulse *number*.

### Freezing is not only an optimisation — it preserves the treasury

Node health is at a fixpoint once stalled. **The treasury is not.** Money demand from water plants
(5), transit hubs (4) and parks (3) is not health-scaled, while money *production* is, so a stalled
city with any of those types drains toward zero. Measured, three dead houses plus one dead park
starting at 100:

| ticks after stalling | money |
|---|---|
| 1 | 97.0 |
| 5 | 85.0 |
| 20 | 40.0 |
| 40 | 0.0 |

So the freeze is a behaviour change, not merely a saving: whatever the treasury held at the moment
of collapse is preserved, and that residue is exactly what a rescue would be paid for. The
consequence worth stating plainly: **`game_over?` is decided at the instant a city stalls and can
never afterwards be entered by the passage of time.** Without the freeze, the first city in §6 —
stalled holding 141.4 — would slide into game over about 40 ticks later.

It can still be entered by *player action*, because `place` and `demolish` both spend. That is
correct and needs no special handling: the predicate is evaluated on live metrics.

### The freeze is not a lockout

`handle_call({:place, …}, …)` does not tick. It edits the map, recomputes metrics and broadcasts. So
a stalled player with money left can still build, `stalled` flips to false on the recomputed metrics,
and the clock resumes on the next pulse with no extra code.

This is reachable, not theoretical. A city of residential blocks alone has **no money demand at
all** — residential consumes none — so its treasury never drains: measured, three dead houses
holding 105 still hold exactly 105.0 after twenty ticks.

**Unfreezing and rescuing are two different things, and an earlier draft of this section conflated
them.** It claimed 80 of that treasury buys a `power_plant` which "takes the three houses back out
of deficit — measured, 10.0 average health ten ticks after the placement". The figure was real and
the conclusion was wrong. Ten ticks after that placement the nodes are:

```
{residential, 0.0}  {residential, 0.0}  {residential, 0.0}  {power_plant, 40.0}
```

The houses never moved. `10.0` is `40 ÷ 4` — an average with three zeros hidden inside it, and the
one non-zero term is the new plant *decaying*. A power plant draws 20 water and 12 waste of its own,
which takes water from 36/40 to **56/40**; water simply replaces power as the binding constraint, at
a worse ratio (0.714 against 0.889). It also supplies no labour, so the plant starves from its first
tick.

Two claims survive that correction, and they are the ones this design rests on:

* **Building anything unfreezes the city**, because the new block starts at full health and
  `stalled?` requires *every* node to be on the floor. That is all the freeze clause needs — the
  clock resumes and the player can keep acting.
* **A demolition is the real rescue, and it is the cheap one.** Measured: three dead houses,
  demolish one for 10, and the remaining two are inside the `15n ≤ 40` cliff — health 10.0 across
  both after ten ticks, from a treasury of 0. This is the same fact §2 uses to set the bankruptcy
  threshold, and it is why that threshold is 10 rather than 15.

Demolition is not a universal escape either: five dead houses minus one leaves four, still 60 power
against the free baseline of 40, still stalled. The cliff is what decides it, not the act.

That is why §5 gives the solvent case its own wording. "Game over" is reserved for the state where
the claim is provable.

## 4. The wipe

### `CityMap.reset/1`

```elixir
def reset(map), do: new(map.width, map.height)
```

Tick 0, no nodes, `money` back to `@opening_grant` through the struct default. No new arithmetic —
the one existing definition of "a new city" is reused, which is the same reason `opening_grant/0`
was extracted in the first place.

### `Ports.SnapshotRepository.delete/1`

New callback, `@callback delete(String.t()) :: :ok | {:error, term()}`.

Necessary, and this is the subtle part of the design. `save/3` is contractually monotonic in tick:
both adapters return `{:stale, stored}` and write nothing when `stored >= tick`, which is the
guarantee that a crashed-and-replayed engine cannot overwrite newer work with older. A reset to
tick 0 is therefore **unsaveable** until the new city's tick climbs back past the stored one — at
one tick per second, a city that ran two hours would be unsaveable for two hours. Meanwhile the
engine stops itself 30s after its last viewer leaves, so closing the tab and reopening it would
re-hydrate the collapsed city that was just wiped. The reset would silently undo itself.

Deleting the row is the honest fix — a wipe really does discard the old city — and it leaves the
monotonicity guarantee completely intact for every other caller. The rejected alternative, a
force flag on `save/3`, is in §7.

Implementations: `SnapshotStore` deletes the one row by `city_id`, following the module's existing
never-raise policy (`rescue`/`catch` to `{:error, term()}`). `FileSnapshotStore` removes its
envelope. Both must treat "nothing stored" as `:ok` rather than an error — a reset of a city that
has never been checkpointed is ordinary.

**The new callback's cases belong in `test/support/snapshot_repository_contract.ex`**, the shared
module an adapter's test `use`s to gain the whole contract. Putting them there is what makes both
shipped adapters, and any future one, prove the same behaviour — including the "nothing stored is
`:ok`" rule above, which is the clause an adapter is most likely to get wrong on its own.

The three test doubles (`stub_snapshot_repository.ex`, `slow_snapshot_repository.ex`, and the
contract module itself) need the callback; that is a mechanical sweep, not a design question.

### `UseCases.ResetCity`

```elixir
@spec execute(CityMap.t()) :: {:ok, %{city_map: CityMap.t(), metrics: SimulationMetrics.t()}}
```

Pure, mirroring `AdvanceCityTick.execute/1`, including computing metrics from the *new* map. It
exists so `CityEngine` — which may not reach `Domain.Services` — can get metrics for the reset city
by the same route it already uses for everything else.

### `CityEngine.handle_call(:reset, …)`

In order:

1. `ResetCity.execute(state.city_map)`.
2. `snapshot_repository().delete(state.city_id)`.
3. `save(state.city_id, city_map)` — immediately, not at the next checkpoint, so the tick-0 city is
   durable before the player can close the tab.
4. Broadcast `:city_reset`, then `{:city_metrics, metrics}`.
5. Reply `:ok` with `critical?` re-seeded from the new metrics — an empty city has no deficit, so
   `false`, which re-arms the notification for the next city.

**The ordering does the error handling.** If the delete fails, step 3's `save` returns
`{:stale, stored}` and lands in `CityEngine`'s existing warning path — the one log line that already
means "this engine's city is older than what is stored". No new failure policy, no new branch. The
in-memory reset still happens and the player still gets a clean grid; the accepted consequence is in
§8.

`:city_reset` carries no payload. The stream is cleared, not diffed, and the metrics broadcast that
follows carries everything else.

## 5. Presentation

**One button, in the page header, and two status blocks that do not repeat it.**

| Condition | Shown |
|---|---|
| wipe gate (below) | **Reset** button in the header, beside the theme toggle |
| `game_over?` | **Game over** banner above the grid — status only |
| `stalled` and not `bankrupt` | **City stalled** panel above the grid — status only |

The gate is a superset of both banner states (see the nesting note below), so the button is always
present whenever a banner is. The banners therefore name the control — "**Reset** in the header" —
rather than rendering a second copy of it. One render site, one event handler, one thing to test.

### The button lives in the header, via a new slot

`Layouts.app` gains `slot :actions`, rendered in the header's right-hand group beside the theme
toggle. `SimulatorLive` fills it. Slot content is compiled into the *caller's* template, so
`phx-click="wipe"` still targets the LiveView — the layout stays a stateless function component and
learns nothing about collapse, treasuries or node types.

`SimulatorLive` is the only caller of `Layouts.app`, so the slot is additive and breaks nothing.

**One layout fix is required, and it was found by measuring rather than by reading.** The header's
right-hand group is `<div class="flex-none">`, and daisyUI's `.flex-none` is `flex: none` — a flex
*item* property, not `display: flex`. A button inserted there stacks *above* the theme toggle
instead of sitting beside it, growing the header from 64px to 77px at every viewport width. The
group must become `flex flex-none items-center gap-2`.

### The button: label, size and colour are all measured, not chosen

```heex
<button class="btn btn-xs btn-error text-white min-h-6" phx-click="wipe"
        title="Clear every block and start a new city — this cannot be undone">Reset</button>
```

Three properties, each pinned by a measurement rather than by taste:

* **Label "Reset", 49px** — against 69px for "Wipe city". Twenty pixels back is the difference
  between the wordmark fitting and not at 375 (below). "Reset" reads milder than "Wipe city" for an
  action that is irreversible and unconfirmed, so the consequence moves into the `title` tooltip and
  the banner copy, both of which say *this cannot be undone*.
* **`min-h-6` (24px), not bare `btn-xs` (21px)** — WCAG 2.2 AA target size is 24×24, and 21px fails
  it. `btn-sm` clears it at 35px but costs 48px of width, which is what pushes the wordmark over.
  `btn-xs` plus a min-height is 49×24: passes, at the narrow size.
* **`text-white`, not daisyUI's `btn-error` default** — measured contrast of `--color-error-content`
  on `--color-error` is **4.08:1 in both themes**, below the 4.5 AA floor for small text. Pure white
  on the same background is **4.60:1** and passes in both. (`btn-outline` was also tested: 4.22
  light / 4.33 dark — also fails.) The instrument was validated against a known pair, black on white
  = 21.00, after a first attempt returned a nonsense 1.00 for a visibly red button.

### The wordmark becomes a two-column grid

Placing the button in the header squeezes the brand, and the *subtitle* is what suffers: today it
sits in the same column as the title, so it gets only the title's 152px while needing 146px, and any
squeeze wraps it onto two lines. The fix is to let it span the full brand width, starting under the
logo, right-aligned so it shares a right edge with the title:

```heex
<a class="grid w-fit grid-cols-[auto_min-content] items-center gap-x-3 gap-y-0.5">
  <.city_mark />
  <span class="text-base font-semibold tracking-tight">Armchair Metropolist</span>
  <span class="col-span-2 text-right text-[11px] opacity-60">city infrastructure simulator</span>
</a>
```

The title stays in column 2, beside the logo, wrapping to two lines there — wanted, not tolerated.
Only the subtitle moves to its own full-width row.

**`min-content` on the second column is load-bearing, and `1fr` is the trap.** `text-align: right`
aligns to the *column box*, not to the text inside it. With `1fr` the column stretches to fill the
brand — 146px wide at 375, while the wrapped title only inks 82px of it — so right-aligning pushed
the subtitle **64px past** the visible title. `min-content` sizes the column to the longest word
("Metropolist"), so the box edge and the ink edge coincide and the alignment is exact.

Measured at both ends, subtitle-right-edge minus title-right-edge:

| column | 375 viewport | 1932 viewport |
|---|---|---|
| `1fr`, left-aligned | +16 | −54 |
| `1fr`, right-aligned | **+64** | 0 |
| **`min-content`, right-aligned** | **0** | **0** |

It also makes the brand *narrower* — 146px instead of 194 (375) and 200 (1932) — which hands the
header back width rather than spending it.

### Measured: line counts, and the sidebar is untouched

Measured 2026-08-06 against the running app, with the header group corrected to a flex row and the
grid applied via inline styles (the utility classes are absent from source, so a class-based mock is
a no-op — see the method note in §6).

At viewport **375**, the narrowest case, counting rendered lines against a forced-single-line clone:

| variant | title lines | subtitle lines | header height | button |
|---|---|---|---|---|
| today, no button *(baseline)* | 1 | 1 | 64 | — |
| today + "Wipe city" | 2 | **2** | 87 | 69×24 |
| today + "Reset" | 2 | 1 | 76 | 49×24 |
| **grid + "Reset"** | **2 (beside logo)** | **1** | **71** | **49×24** |

The chosen row restores the baseline's single-line subtitle with the button present, and costs 7px
of header height on a city that is dead anyway.

At viewport **1932** the grid holds and nothing else moves:

| | baseline | with the button and the grid |
|---|---|---|
| header height | 64 | 71 |
| wordmark width | 200 | 146 |
| header overflows | no | no |
| **aside width** | **1360** | **1360** |

**The aside figure is the point, and only its equality matters** — the absolute number tracks what
the legend currently contains and will differ between cities. Unchanged with and without the button
means the wrap thresholds documented in `SimulatorLive.render/1` — expanded 2335, collapsed 1415
with *zero slack* — are not merely protected but structurally out of scope. Nothing in this design
goes inside the `<aside>`, and no threshold needs re-measuring. The banners sit above the grid, also
outside it.

### The wipe gate

```elixir
not housing_alive and (node_count > 0 or bankrupt)
```

Written in terms of `bankrupt` rather than restating `money < Node.cheapest_action_cost()`, so the
threshold has exactly one reader. A second copy here would be invisible to anyone searching for the
constant's own value.

The first disjunct is the ordinary case: blocks are standing and no housing is alive.

The second exists for a dead end the first disjunct alone creates. Demolishing costs 10 and clears a
node, so a player can spend down to an empty grid holding 9 — no nodes, so not stalled and no
banner; no nodes, so the first disjunct is false; nothing costs 10 or less; and an empty grid earns
nothing, forever. The second disjunct is the escape hatch for exactly that position.

Together they still hide the button on a fresh city, where the wipe would be a no-op — which is the
only reason the gate is not the bare `not housing_alive`.

Note the nesting, which is why the banner and panel need no separate condition: `stalled` forces
every node to health 0.0, hence every residential to 0.0, hence `not housing_alive`, and it requires
`node_count > 0`. So the gate holds in both banner states automatically.

### The banners are exactly as wide as the grid

```heex
<div style={"width: #{@width * @cell_size}px"} class="max-w-full box-border …">
```

Same expression the grid itself uses in `render/1`, so the two cannot drift — 960px today, and
automatically correct if the grid dimensions or `@cell_size` ever change. A `max-w-*` prose measure
such as `72ch` would have been a second, unrelated number that merely looked close.

`max-w-full` and `box-border` are both required. Measured at 375, the banner clamps to the
container's 343px instead of overflowing to 960; the grid keeps its own pre-existing horizontal
overflow, which this does not touch. Without `box-border` the padding and border would push it past
the grid's right edge at every width.

### The copy, verbatim

**Game over** (`game_over?`):

> **Game over — this city is dead.**
> Every block is dead and starving, so the clock has stopped. Building costs at least 15 and
> demolishing costs 10, and the treasury holds *N* — so nothing can restart it. **Reset** in the
> header clears the grid and starts a new city. This cannot be undone.

**City stalled** (`stalled`, solvent):

> **City stalled — nothing is changing on its own.**
> Every block is dead and starving, so the clock has stopped. The treasury still holds *N*:
> building always restarts it, and demolishing can too. Or **Reset** in the header to start over.

The headline is a verdict and the sentence under it is the mechanism, deliberately in that order. A
verdict is what a player wants first, and this one is *earned* rather than asserted — ticks are
ignored while stalled, so health, tick and money are all constant; every `place` needs at least 15
and every `demolish` needs 10, both above the treasury; therefore nothing but the reset can change
the city. That proof is what the second sentence carries, and it is what keeps "dead" from being the
kind of unbacked classification that has gone stale in this project's prose before.

The two headlines are opposites on purpose, and that contrast is the whole reason the states are
separated: one says nothing *can* change, the other says nothing *is* changing but you can still
act. Both name the treasury figure, because that number is what decides which of the two a player is
looking at.

### Events

`handle_event("wipe", …)` calls `CityEngine.reset/1` and, on `:ok`, clears the stream with
`stream(:nodes, [], reset: true)`. `handle_info(:city_reset, …)` does the same for every other
viewer. Both, matching the existing place/demolish pattern, where the caller updates its own stream
and the broadcast serves the rest; clearing twice is idempotent.

Single click, no confirmation — see §7.

## 6. Measured findings

Every figure in this document came from running the domain, not from reading it. Recorded here so
the implementation can be checked against the same numbers.

**Method note, for whoever re-measures the header.** Every layout figure here was taken by injecting
into the running page, and three separate readings had to be thrown away first:

* **Utility classes assigned at runtime do nothing.** Tailwind emits only what it finds in *source*,
  so `grid`, `grid-cols-[auto_1fr]` and `btn-error` were all inert when set from the console — the
  first mock produced an accidental stacked layout that looked plausible and was not the proposal.
  Mock with inline styles, and assert the effect (`getComputedStyle(el).display === 'grid'`) before
  believing any measurement. The same classes written into the `.heex` compile normally.
* **A stylesheet scan is the wrong instrument for "does this class exist".** Matching
  `rule.selectorText` against `.btn` reported *false* for every daisyUI class including ones
  demonstrably styling the page, because daisyUI v5 wraps its selectors in `:where()`. Measure the
  effect, not the mechanism.
* **Viewport emulation persists across resizes, and `window.innerWidth` lies under it.** After a
  mobile preset, a later resize left the header laying out at 375px while `window.innerWidth`
  reported 1012 — and under the preset itself the *layout* width of 375 is correct while
  `innerWidth` is the wrong one. So do not assert `header.width ≈ window.innerWidth`: assert
  `header.width === <the width you meant to test>`, and reload after every resize.
* **Mutations survive between probes.** Several readings were taken against a brand that an earlier
  probe had already restructured, so the "original" snapshot was not original and one run threw
  `appendChild: parameter 1 is not of type 'Node'`. Reload before each mock and assert the pristine
  shape (`a.children.length === 2`) before capturing anything.
* **LiveView patches injected DOM away on the next tick.** Disconnect the socket
  (`liveSocket.disconnect()`) before mocking, and hide `#flash-group` — the disconnect banner lands
  exactly over the header's right-hand group.

**Cheapest action.** Construction: residential 15, park 20, transit_hub 40, commercial 40,
industrial 60, water_plant 70, power_plant 80. Demolition 10, flat. `cheapest_action_cost` = 10.0.

**The bankruptcy threshold discriminates.** Three dead houses holding 9: every one of the eight
possible commands — one demolish, seven placements — returns `{:error, :insufficient_funds}`. The
same city holding 10 can demolish, and doing so recovers it. A fixture at 0 would not tell `< 10`
apart from `== 0`.

**Collapse run to completion, from a 150 grant spent on the listed blocks:**

| city | stalls at tick | money at stall | game over? |
|---|---|---|---|
| 4 house + water_plant + park + commercial | 41 | 141.4 | no |
| 6 house (no money demand) | 31 | 153.0 | no |
| 3 house + transit_hub | 68 | 0.0 | **yes** |

Game over is reachable from ordinary play, and it is the minority outcome: it needs sustained money
demand that outruns earning. A commercial block earns faster than it dies, so the first city stalls
richer than it started. That is the evidence for keeping `stalled` and `bankrupt` as separate facts.

## 7. Rejected alternatives

**A confirmation step on the wipe.** Proposed as a two-click arm-then-commit, because the gate fires
before the city is dead: setting aside §6's third row, a city can have no living housing while blocks
still stand and the treasury holds real money. Rejected on the explicit instruction that a single
click is truer to the requirement. The risk is recorded in §8.

**Ending on `avg_health == 0` alone, per the original phrasing.** Rejected: it fires on a fresh grid
(§2) and on 1–2 house cities one tick before they recover (§2).

**Ending when no residential is alive.** Rejected as an *end* condition — it fires while blocks are
still visibly alive and, more importantly, while a rescue may still be affordable. It survives as the
wipe gate, where offering an escape early is the point.

**Keeping the tick counter running instead of resetting it.** Would avoid the persistence problem
entirely and needs no port change. Rejected in favour of a genuinely fresh city; the tick is the
age of the current layout, and a wiped city has none.

**A force flag on `save/3` instead of `delete/1`.** Fewer moving parts, but it puts a hole in the
exact guarantee that stops a replayed engine clobbering newer work, and the flag is one mistaken
caller away from being that bug. A delete is a different operation with different semantics rather
than an exception carved into an existing one.

**Waiting N consecutive zero-health ticks before ending.** Distinguishes stuck from healing
empirically without modelling recovery, but adds engine state and picks an arbitrary N when an exact
predicate is available.

## 8. Accepted consequences

**A misclick on the wipe destroys a recoverable city.** The gate can hold while blocks stand and
money remains, there is no confirmation, and the delete makes it unrecoverable. Accepted on
instruction; the mitigation is that the button is hidden entirely while any housing is alive, which
is the state a player who is still playing normally is in.

**Putting it in the header sharpens that slightly**, because it lands beside the theme toggle — a
control people click casually and repeatedly — rather than in a sidebar nobody clicks by accident.
The gate is what keeps this acceptable: the button is absent from the chrome during ordinary play,
so it never becomes part of the furniture the way the toggle is. It should be styled as destructive
(`btn-error`) rather than as neutral chrome, so it does not read as another settings control.

**Partial fixpoints are not detected.** A live house beside a permanently dead water plant never
changes again, but it has positive average health, so it is neither stalled nor frozen and the engine
ticks it forever. Deliberate: the player can still act there, income is still arriving, and the
requirement was scoped to full collapse. It does mean "the sim ends when nothing can change" is
*not* what ships — what ships is "the sim ends when every block is dead and staying dead".

**A failed snapshot delete leaves a reset that does not survive a restart.** The player sees a clean
grid; a later hydration restores the old city. Logged as the existing stale-save warning. Accepted
because reaching it requires the repository to be failing, in which case checkpointing is already
broken and the city is already at risk — and because the alternative, surfacing a storage error in
the game UI, tells the player something they cannot act on.

**The treasury survives collapse, where before it drained.** A stalled city keeps whatever money it
had. This makes the game slightly more forgiving and makes `game_over?` rarer than it would
otherwise be. It is the direct consequence of freezing and is the reason the stalled-but-solvent
state has its own panel rather than being folded into the banner.

**`docs/PLAYING.md`'s existing collapse language needs revisiting.** It documents the collapsed state
as reachable and measured over 150 ticks. With the freeze, "still 0.0 after 150 ticks" is true for a
different reason than it was — the ticks are not being run. §9 covers this.

## 9. Documentation

`docs/PLAYING.md` gains a section, and one existing passage is re-checked rather than assumed.

The new section states mechanisms, not verdicts — the failure mode this guide has hit before is
sentences that hand out a classification, while every sentence stating a mechanism survived:

* What stalls a city: every block at zero health with at least one of its inputs short.
* That one or two houses alone heal from zero on an empty treasury and three do not, with the
  `15n ≤ 40` arithmetic that decides it.
* That a stalled city's treasury is frozen rather than draining, and can buy a rescue — a power
  plant for a housing-only collapse, or a single demolition for 10.
* That game over means the treasury was already below 10 when the city stalled, and why nothing can
  change from there.
* What the wipe restores: empty grid, tick 0, the opening grant, and the stored city discarded.

Two existing passages are re-read against the freeze rather than assumed unaffected:

* **The demolition-as-escape paragraph** (`docs/PLAYING.md` §"Placing and demolishing"): "it is how
  you get out of a collapse — but at the fee above, which means the escape has to be bought while
  there is still something to buy it with." This is exactly the `bankrupt` threshold stated in
  player language, and it is already correct. The new section should point at it rather than restate
  it.
* **The 19-dead-blocks rescue simulation**: "every node's health is still 0.0 after 150 ticks."
  Still true of the calculator, which is what produced it — but with the freeze, a player never
  watches 150 such ticks, because the engine stops. The sentence needs its framing checked even
  though its arithmetic stands.

**No generated block changes, and this was checked rather than assumed.** `test/support/playing_guide.ex`
drives every measured block through `SimulationCalculator.advance_tick/1` directly; the freeze lives
in `CityEngine`, which the generator never touches. So `playing_guide_test.exs` should stay green
without regeneration. If it does not, that is a real finding and not a formatting nuisance.

## 10. Testing

### Mutation-sensitive cases

Each of these must go red under a stated mutation; a test that cannot fail is worse than no test.

*`stalled`* — drop the `nodes != []` clause and a fresh city stalls: assert a new
`CityMap.new(40, 30)` is not stalled. Weaken `worst_satisfaction < 1.0` to `true` and two dead houses
stall: assert 2 dead houses are not stalled and 3 are, in the same test file so the boundary is
visible. Relax `health == 0.0` to `health < 20.0` and a healing city stalls: assert a city of houses
at health 10 with every input satisfied is not stalled.

*`housing_alive`* — assert false for houses at exactly 0.0 health (a count-based reading returns
true), and true for one house at health 5 among dead blocks (a status-based reading returns false).
Those two fixtures are what separate the three readings.

*`bankrupt`* — assert true at 9.0 and false at 10.0. A fixture at 0.0 cannot tell `< 10` from `== 0`.

*`game_over?`* — assert false for stalled-and-solvent and false for bankrupt-and-healthy, so
swapping `and` for `or` goes red.

*`cheapest_action_cost`* — assert it equals the minimum over demolition and every construction cost,
derived in the test rather than restated as 10.0, so a balance patch cannot leave the two disagreeing.

*The freeze* — assert a stalled engine's `city_map.tick` is unchanged after a tick message, and that
a healthy engine's is not. Both directions: a freeze that never fires and a freeze that always fires
are different bugs.

*The freeze is not a lockout* — two cases, because unfreezing and rescuing are different (§3).
Place a block into a stalled solvent city through the engine and assert `stalled` is false: that
covers the mechanism, since the new block is at full health. Then demolish one of three dead houses
for exactly 10 and assert the remaining two recover — that covers the claim the game-over threshold
rests on. Seed that second case at exactly 10.0: at 9 the command is refused and the test asserts
nothing at all.

*The reset* — assert nodes empty, `tick == 0` and `money == CityMap.opening_grant()`, each named
separately so a reset that forgets one is caught. Assert the repository's `delete/1` is called before
the save, using a stub that records call order — the ordering is the error handling, so it is
behaviour and not an implementation detail. Assert that a `delete` returning `{:error, …}` still
resets in memory.

*`delete/1` itself* — cases go in `snapshot_repository_contract.ex` so both adapters run them:
deleting a stored city makes the next `load/1` return `{:error, :not_found}`; deleting a city that
was never stored returns `:ok`; and — the case that ties this back to §4 — after a delete, a
`save/3` at a tick *below* the previously stored one succeeds, which is the whole reason the
callback exists.

*The wipe gate* — four cases: healthy city (hidden), no living housing with blocks standing (shown),
empty grid with 9 money (shown, the dead end), fresh city (hidden). Dropping either disjunct reddens
one of the middle two. Asserted against the header button's own id, which is the single render site.

*The banners do not duplicate the button* — assert that a game-over render contains exactly one wipe
control. Without this, a later edit that helpfully adds a button back into the banner ships duplicate
DOM ids and a second untested event path, and nothing else in the suite would notice.

*The layout slot* — assert the header renders the button beside the theme toggle rather than above
it. This is the `flex-none` finding from §5 and it is invisible to every content assertion: the
button is present, clickable and correctly labelled in both arrangements, so only a geometric or
class-level check can see it. A class assertion on the group (`flex` present) is the cheap version
and is enough to stop a regression that drops it.

*The wordmark grid* — same category, same blind spot. Assert the subtitle span carries
`col-span-2` and `text-right`, and that the brand carries `grid-cols-[auto_min-content]`. Every one
of those is invisible to a content assertion, and dropping `min-content` for `1fr` silently
un-aligns the subtitle by 64px without changing a single rendered character.

*The banner width* — assert the banner's inline width is derived from `@width * @cell_size` rather
than a literal 960, so a grid-dimension change moves both together.

*The two headlines are distinguishable* — assert the game-over render contains "this city is dead"
and the stalled-solvent render does not. Both banners share their second sentence, so an assertion
on the shared prose passes against the wrong state; the headline is the only text that separates
them.

### Not needed

No snapshot round-trip test for the new metrics fields — metrics are not persisted. No
`SnapshotVocabulary` fixture change for the same reason: no new atom reaches a stored `CityMap`.
