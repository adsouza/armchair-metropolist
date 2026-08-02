# Legend collapse: keep selection and metrics — design

**Date:** 2026-08-02
**Status:** approved, not yet implemented

## 1. Problem

Collapsing the legend currently removes the player's only way to choose a block type and
hides the metrics as well. Two separate defects share one cause and one fix.

**Selection disappears.** The type row *is* the selection control — the previous *Place*
button row was deleted when the sidebar landed. Collapsing the sidebar therefore leaves no
affordance for changing what gets placed on the next click.

**Metrics disappear.** The metrics block is rendered *inside* `legend/1`, under the same
`:if={@sidebar_open}`. It has no independent existence, so hiding the legend necessarily
hides tick, node count, average health and offline count.

**The layout commits to a width it cannot honour.** The breakpoint is `min-[1450px]`, but
the matrix needs `960 grid + 16 gap + 655 matrix = 1631px`. Between 1450 and 1631 the page
goes side-by-side and then cannot fit, so the table scrolls horizontally inside the sidebar.
An earlier task nearly fixed this by raising the number to 1640; review found a different
bug (a missing `min-w-0`) and reverted the change, and the number was never restored.

### Non-goals

* No change to any simulation rule. Presentation over existing state.
* No new domain data. The tightest-resource figure is derived from `@metrics.resources`.
* No second selection UI. One control, in one place, in both states.

## 2. Why collapsing exists

To let the window be narrower. The grid is a fixed 960 × 720 (`@width * @cell_size`, inline
style) and never grows, so width reclaimed on a wide window is dead space — the payoff is
entirely in what the window can shrink to.

That makes the collapsed *width* the whole feature, and it is why the caption handling in
§4 is load-bearing rather than cosmetic.

## 3. Layout: let the content decide

Replace the media-query breakpoint with content-driven wrapping:

* the row becomes `flex flex-wrap items-start gap-4`
* the `<aside>` becomes `min-w-fit` (`min-width: fit-content`)
* every `min-[1450px]:*` class is deleted

The sidebar then sits beside the grid exactly when it fits and drops below when it does not,
with no threshold to maintain. Measured in the browser:

| state | sidebar width | beside | below |
|-------|---------------|--------|-------|
| expanded | 655px | ≥ 1632px | ≤ 1631px |
| collapsed | 127px | ≥ ~1103px | narrower |

1632 is exactly `960 + 16 + 655 + 1`. Because the threshold is derived rather than written
down, adding a resource column or a longer type name moves it automatically — the failure
mode a hard-coded 1640 would reintroduce the moment the table changed.

The sidebar can no longer be squeezed below its own content, so **the internal horizontal
scrollbar cannot appear**. `overflow-x-auto` stays on the table wrapper as a safety net for
viewports narrower than the sidebar itself; it was verified not to affect the wrap point.

Below roughly 1024px the *page* scrolls horizontally regardless, because the grid is a fixed
960px and `shrink-0`. That is pre-existing and out of scope.

**Implementation note.** Tailwind's JIT only emits classes it finds in source. `flex-wrap`
and `min-w-fit` appear nowhere in this project today, so they must be written into the
template — injecting them at runtime does nothing, which invalidated two measurement runs
during design.

## 4. The collapsed state

Collapsed hides:

* the four resource columns (`<th>`/`<td>` from the third column on)
* the totals row
* the totals caption, *"Totals include the free baseline of 40 per resource…"*

Collapsed keeps the type column — still real `<button>` elements with `phx-click="select_type"`
— and the count column. Row ids, order and selected-row highlighting are unchanged, so
nothing moves when the state flips.

**The caption is not cosmetic.** A long text line sets the sidebar's `fit-content`, not the
table. Left visible, it holds the collapsed sidebar at **437px**; hidden, the sidebar is
**127px**. Without hiding it, collapsing reclaims almost nothing and the feature fails its
one purpose. It also describes the totals row, which is itself hidden.

## 5. Metrics move out of the legend

`metrics/1` becomes its own private function component, a sibling of `legend/1` inside the
`<aside>`, rendered unconditionally — never under the collapse condition. This is the
structural fix for "never hide the metrics": today the block cannot survive a collapse
because it is nested inside the thing being collapsed.

It keeps tick, node count, average health and offline count, and gains one line:

```
Tightest: water 71%
```

the resource with the lowest satisfaction, from `@metrics.resources`. Per-resource
satisfaction otherwise lives only in the totals row, which collapsing hides;
`docs/PLAYING.md` calls the lowest figure "the only number that matters", so it is the one
figure that must survive. Full per-resource detail returns when expanded.

The computation is a `min_by` over an existing map — presentation, not simulation. No domain
change, and `ArmchairMetropolistWeb` still touches no `Domain.Services`.

An empty city has satisfaction `1.0` for every resource; ties resolve to whichever
`Enum.min_by/2` returns first, which is stable for a map built from `Node.resources/0`.

## 6. Naming

The control no longer hides the legend, so the vocabulary changes with it:

| now | becomes |
|-----|---------|
| `@sidebar_open` | `@legend_detail` |
| `toggle_sidebar` | `toggle_legend_detail` |
| "Hide legend" / "Show legend" | "Hide detail" / "Show detail" |

`#toggle-sidebar` becomes `#toggle-legend-detail`; the existing tests assert on that id and
move with it. `docs/PLAYING.md` describes the collapsed behaviour and the new label.

## 7. Testing

Against `AGENTS.md:376`, using `element/2` and `has_element?/2` on stable ids:

* collapsed still selects: click a type row while collapsed, assert the selection moved
* metrics survive both states: `#metrics-tick` present expanded **and** collapsed
* `#legend-totals` absent collapsed, present expanded
* resource cells (`[data-cell="power_plant-power"]`) absent collapsed, present expanded
* the count cell (`[data-cell="power_plant-count"]`) present in both
* the tightest line names the lowest-satisfaction resource, with a fixture where the four
  resources differ so a wrong pick cannot pass
* the toggle's own `aria-expanded` and label track the state in both directions

Every new assertion is mutation-verified individually — broken, watched fail on its *own*
test, restored. This project has shipped eight assertions that could not fail; the two most
recent were in this same file.

The wrap behaviour is CSS with no JavaScript and no server state, so it is verified in a
browser at 1700 / 1632 / 1631 / 1103 / 1000 rather than in ExUnit.

## 8. Risks

* **`min-w-fit` support.** `min-width: fit-content` is well supported, but if a target
  browser disagrees the sidebar would shrink and the old scrollbar returns. The webview here
  is WKWebView (macOS) and WebKitGTK (Linux); both support it.
* **Collapsed width is content-dependent.** Any long unbroken string added to the sidebar
  re-inflates `fit-content`, exactly as the caption did. Anything added there must be short
  or wrappable.
