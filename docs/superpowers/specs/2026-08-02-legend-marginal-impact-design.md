# Legend: show the marginal impact of one more block — design

**Date:** 2026-08-02
**Status:** implemented

> **Post-implementation correction.** Every matrix width in §2 is wrong, and so is the claim
> that "the threshold stays 1711". They were taken from `getBoundingClientRect()` on a table
> that daisyUI styles `width: 100%`, inside an `<aside>` carrying `grow` — so each reading was
> the *container's* width, not the matrix's. The matrix's natural width is 757px and barely
> moves with content: swapping every total for `+9999 → +9999` changes it by zero.
>
> The width argument in "Why stacked rather than inline" therefore rests on bad numbers, though
> its conclusion survives — inline still costs width that stacked does not. The thresholds are
> now 1900 (expanded) and 1287 (collapsed), chosen as midpoints of measured windows rather than
> as wrap points; see the comment in `render/1`.

## 1. Problem

The legend answers "what have I got" but not "what will this do". `build_by_type` multiplies
every figure by the number placed (`simulation_metrics.ex:89-91`), so a type with none placed
renders `+0` in every column. On a fresh city the `power_plant` power cell reads **`+0`**.

The one number needed to choose what to place — the impact of one more block — is the one
number the legend never shows, and it is missing precisely for the unplaced types the player is
choosing between.

This is purpose #1 of the original legend spec ("what does each block type do to each
resource") lost to the `× count` that serves purpose #3 ("what they add up to").

### Non-goals

* No simulation change. Presentation over existing state and the domain's own tables.
* No change to the totals row, the count column, or the collapse behaviour.
* No new domain data — see §3.

## 2. The cell

Each resource cell becomes two lines:

```
+120            ← per block, text-secondary
+360 → +210     ← city total, font-semibold, default colour
```

**Line 1 — per block.** The type's *rated* net effect on that resource for one block:
`production − consumption`, unscaled. Rated is the correct marginal figure because a newly
placed node starts at full health, so its contribution is its rated figure.

**Line 2 — city total.** Exactly today's cell, semantics unchanged, including the
`rated → actual` divergence form that appears only when the two differ once rounded.

**Omitted cases.** A type that does not touch a resource renders `—` on line 1 and no line 2.
With none placed, line 2 is omitted rather than reading `0` — the total is not interesting
before anything exists, and the per-block figure is the whole point of that row.

### Why stacked rather than inline

Width is scarce and height is free. Measured worst case, every cell at maximum content:

| format | matrix width | table height |
|--------|--------------|--------------|
| today | 655px | 269px |
| inline `+360 → +210 (+120 ea)` | **766px** (+111) | 269px |
| stacked | **655px** (+0) | 353px (+84) |

Inline would raise the wrap threshold from 1711 to ~1822 and put the legend below the grid at
the 1719px window this is developed on. Stacked costs nothing in width, and the 84px of height
lands against a 720px grid that the sidebar sits beside. The threshold stays 1711.

### Emphasis and colour

Line 2 is **bold** (`font-semibold`) in the default `base-content` colour; line 1 is
`text-secondary`. Two channels distinguish them — position and weight — so colour is
reinforcing rather than load-bearing, which keeps the cell readable for colour-blind users.

`text-secondary` was chosen over `text-info` on contrast grounds: the light theme defines
`--color-info` at 62% lightness, which on a near-white background is marginal for small text,
while `--color-secondary` is 55% (light) and 58% (dark) — mid-lightness against both
backgrounds. The app ships light and dark themes with a user-facing toggle, so any colour must
work in both. **Contrast is to be measured in both themes after implementation, not assumed**;
if either falls below 4.5:1 the choice changes.

Note both classes must be written into the template to exist at all — Tailwind's JIT emits only
what it finds in source, and none of `text-secondary`, `text-info` or `text-base-content`
appears in this project today.

## 3. Where the per-block figure comes from

`Node.production/1` and `Node.consumption/1` directly — **not** `by_type`.

The per-block impact is a property of the *type*, fixed by the domain's tables; it does not
vary with the city and therefore does not belong in a metrics snapshot. Putting it in `by_type`
would mean recomputing a constant on every tick and broadcasting it.

`ArmchairMetropolistWeb` may call `Domain.Entities.Node` — it is exported, and the view already
calls `Node.types/0` and `Node.resources/0`. The subtraction is display arithmetic of the same
kind `net_cell/2` already performs, and the boundary rule that matters (`Domain.Services` is
unreachable from the web layer) is untouched.

## 4. Testing

* a type with **none placed** shows its per-block figure — `power_plant` power reads `+120` at
  count 0. This is the exact gap; without it the row is all zeros.
* the total line is **absent** at count 0 and **present** at count 3, with the right value.
* the total line keeps the `rated → actual` divergence form.
* a type that does not touch a resource still renders `—`.

Each mutation-verified individually, confirmed to fail on its own test rather than tripping a
neighbour's. Colour and weight are CSS: verified in a browser in both themes, with measured
contrast ratios, not asserted in ExUnit.

## 5. Risks

* **Row height.** Seven rows gain a line each. Measured at +84px against a 720px grid — fine
  beside the grid, and it only lengthens the page further when the sidebar has already wrapped
  below, where vertical space is already the mode.
* **Two numbers per cell is more to read.** Mitigated by weight and colour, and by omitting the
  total line entirely until something is placed, which keeps a fresh city's legend to one line
  per cell.
