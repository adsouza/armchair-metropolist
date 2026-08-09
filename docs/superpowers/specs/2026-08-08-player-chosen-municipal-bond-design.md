# A player-chosen municipal bond issue: runway now, fixed-term debt service — design

**Date:** 2026-08-08
**Status:** implemented in `e060100`
**Supersedes:** the fixed 400 opening grant in `Domain.Entities.CityMap` and every generated
playing-guide claim derived from it. Existing saved cities are grandfathered debt-free; this
design does not assign a liability retroactively.

## 1. Problem

The opening grant does two jobs today, and its fixed size makes them impossible to separate.

* It buys the construction itself. The documented eight-block opening costs 300.
* It buys **time** through the first three loss-making stages. One house, one power plant and
  one transit hub run at −14, −6 and −10 money per tick respectively; commerce at step four
  turns the same city to +6. The current 400 grant sustains the measured route with up to six
  ticks between placements.

The amount therefore sets both the player's margin for error and the rate at which the early
city can expand, but the player gets no say in either. Raising it makes the opening less tense
for everyone and leaves a successful city with more unearned cash. Lowering it makes a first
run fail before the player has learned why.

A municipal bond issue makes that runway a choice with a continuing consequence: issue less and
reach revenue with less margin, or issue more and carry larger debt service through the next stage
of growth.

### Why this is a serial bond rather than a bullet bond

The framing is municipal from end to end: the city **authorizes a bond issue**, receives its
proceeds and services the issue through fixed maturities. Player-facing copy does not describe a
bank, lender or open-ended loan. This both fits the capital-project fantasy and makes the finite
term part of the promise rather than an implementation detail.

An interest-only issue with all principal due only at maturity does not create the intended
decision.
Construction pays back quickly in this economy: the four-block core costs 175 and nets +6 per
tick; the full 300 opening nets +12. At any modest interest rate, reinvesting in another earning
block generally dominates voluntarily reducing principal. With no score or win condition, many
players would rationally defer the principal until the final balloon payment.

The instrument is therefore a **level-principal serial municipal bond issue**: one fixed issue is
divided into equal principal maturities across 100 servicing ticks, with interest on what remains
outstanding. After a disclosed call-protection period, the player may redeem principal early at
par, but cannot choose to pay coupons forever.

### Non-goals

* **No general bond market.** The city authorizes one issue before construction. It cannot reopen,
  refinance, issue a second series or borrow against an established city.
* **No wall-clock or offline interest.** This remains a tick simulation. Nothing advances after
  the engine stops, and a stalled city's clock already stops by design.
* **No bond rating, bondholder, collateral, foreclosure sale or repossession simulation.** Default
  changes affordability and leaves obligations past due; it does not delete blocks.
* **No APR vocabulary.** A tick is one second under today's configuration but is a game unit,
  not a year. Every rate and payment is shown per tick.
* **No arbitrary slider in the first version.** Three issues expose meaningful strategies without
  asking a first-time player to optimize an economy they have not seen.
* **No retroactive debt.** A saved city created under an earlier release keeps its treasury and
  receives a zero-balance legacy financing record.
* **No change to capacity, load, construction-cost, demolition-cost, health or grid-growth
  tables.** The mechanic changes only how a new treasury is funded and what happens at the cash
  boundary of a tick.

## 2. The issues

Three exact issue sizes, selected before the grid becomes interactive:

| issue | principal | role |
|---|---:|---|
| **Lean** | 250 | Least debt; reaches the profitable core but cannot buy the fixed 300 opening outright |
| **Balanced · recommended** | **400** | Replaces the present default; enough for a deliberate direct route |
| **Generous** | 550 | Preserves more of today's reaction margin, in exchange for the largest payment |

The domain authorizes exactly `250.0`, `400.0` or `550.0`. The labels are presentation; the issue
sizes and recommended issue live in `Domain.Entities.MunicipalBond` so the issuance UI, tests and
playing-guide generator cannot disagree.

### Terms

* **Construction-period debt-service holiday:** 20 ticks, beginning with the first successful
  placement. The issue terms fund this construction window: no cash interest or principal is due
  and neither is added to the balance.
* **Fixed maturity:** 100 servicing ticks after that opening period. Missed obligations remain
  past due after maturity; they do not rewrite the term.
* **Serial principal maturity:** `original_principal / 100` on each of the first 99 servicing
  ticks. On the 100th, every remaining principal amount is due. An on-time issue therefore retires
  in 100 equal principal installments; an issue that defaulted cannot hide missed principal behind
  a newly extended schedule.
* **Interest:** `0.5%` of principal outstanding immediately before that tick's payment.
* **Interest arrears:** simple, not compounding. Unpaid interest is carried separately and does
  not itself earn interest.
* **Principal arrears:** a missed serial maturity remains immediately due and remains part of
  outstanding principal. Paying it reduces both figures; it is never added to principal a second
  time.
* **Call protection:** optional redemption unlocks after 20 servicing ticks have elapsed. Missed
  payments do not extend the protection period, but paused ticks do not count.
* **Optional redemption:** allowed at par after call protection. It clears interest arrears first
  and then principal. The maturity date and scheduled serial principal do not recast.

At the start of an on-time schedule:

| bond | principal/tick | first interest | first payment | total interest | total debt service | core after payment | full opening after payment |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 250 | 2.50 | 1.25 | **3.75** | 63.13 | 313.13 | +2.25 | +8.25 |
| **400** | **4.00** | **2.00** | **6.00** | **101.00** | **501.00** | **0.00** | **+6.00** |
| 550 | 5.50 | 2.75 | **8.25** | 138.88 | 688.88 | −2.25 | +3.75 |

The last two columns subtract only the first scheduled payment from the measured +6 and +12
operating flows. Payments decline with principal. The final on-time payments are 2.5125, 4.02
and 5.5275 respectively.

At the first call date, an on-time Lean, Balanced and Generous issue has paid 22.63, 36.20 and
49.78 in interest and has 200, 320 and 440 of principal left. The minimum interest price of carrying
Generous rather than Lean through call protection is therefore 27.15; the other 60 of additional
debt service was principal returned. The larger issue buys real opening optionality, but not for
free.

**The Balanced payment consuming the core's whole +6 is deliberate.** That core is the point at
which the opening stops dying, not the destination. A Balanced player can hold there while the
payment declines, but meaningful cash growth comes from finishing the support chain. A Generous
player has enough unspent principal to finish despite a temporarily negative post-debt core. A
Lean player has the best mature margin but must save at the core before buying the remaining 125
of the documented route.

### Opening-cadence probe

A scratch probe against the current calculator, layering the terms above onto the existing
opening sequence, found:

| bond | largest fixed gap that completed the scripted route healthy |
|---:|---:|
| 250 | none — it must pause and save at the core rather than follow the fixed route |
| 400 | 4 ticks |
| 550 | 6 ticks |

The probe charged debt after the current tick's market purchases, while the final rule below
reserves debt **before** purchases. It is therefore an upper bound, not an acceptance figure.
Implementation must put the real mechanic into `PlayingGuide` and remeasure. The roles above are
the design invariant: Lean must be viable through a save-and-grow route, Balanced must be viable
without frantic clicking, and Generous must buy measurably more reaction time than Balanced.
If the exact results move, tune the construction-period debt-service holiday before changing
construction or resource tables.

## 3. Persisted model

Add a separate entity:

```elixir
defmodule ArmchairMetropolist.Domain.Entities.MunicipalBond do
  @type t :: %__MODULE__{
          original_principal: float(),
          outstanding_principal: float(),
          interest_arrears: float(),
          principal_arrears: float(),
          started_at_tick: non_neg_integer() | nil
        }

  defstruct original_principal: 0.0,
            outstanding_principal: 0.0,
            interest_arrears: 0.0,
            principal_arrears: 0.0,
            started_at_tick: nil
end
```

`CityMap` gains:

```elixir
revision: non_neg_integer(),
municipal_bond: MunicipalBond.t() | nil
```

with struct defaults `revision: 0` and `municipal_bond: nil`. Revision is the persistence-ordering
prerequisite in §10; it is not part of bond arithmetic.

Three shapes have distinct meanings:

| value | meaning |
|---|---|
| `nil` | a new city has not authorized an issue; the grid is not running or editable |
| `%MunicipalBond{original_principal: 0.0, ...}` | a grandfathered city, permanently debt-free |
| `%MunicipalBond{original_principal: p}` where `p > 0` | an issued bond, active or redeemed |

Do not use an atom such as `:unissued` or `:legacy` for state. The shape and principal already
distinguish them, and a persisted state atom would add vocabulary and migration surface without
adding information.

### Why this is an entity and not four flat `CityMap` fields

Payment allocation, the construction-period debt-service holiday, maturity, default and optional
redemption are one invariant. A separate entity gives them one constructor and one transition
function, and prevents a caller from updating principal without updating its past-due subset. It
also keeps `CityMap` from becoming the module that owns every mechanic merely because it is the
persistence root.

It must be in its own file. `CityMap` aliases it; no file contains two modules.

### Public domain operations

`MunicipalBond` owns:

* `issues/0`, `recommended_issue/0`, `opening_period_ticks/0`,
  `call_protection_ticks/0`, `term_ticks/0` and `interest_rate/0`;
* `new/1`, accepting only an exact authorized issue size, and `issue_terms/1`, deriving the
  comparison figures from the same on-time schedule;
* `legacy/0`;
* `issued?/1`, `legacy?/1`, `debt_free?/1`, `defaulted?/1`, `callable?/2` and
  `redemption_amount/1`;
* `start/2`, which records the first-placement tick once;
* `quote/2`, returning opening-period, call-protection and maturity ticks remaining, current
  interest, current and past-due serial principal, interest arrears and total due without changing
  the bond;
* `service/3`, applying one scheduled payment from an available cash amount;
* `redeem/3`, accepting the current tick and applying an eligible optional redemption to arrears
  and then principal.

The entity never reads nodes, capacity, imports or a city treasury. It receives a tick and an
available amount, then returns exact financing arithmetic. `SimulationCalculator` owns where that
amount comes from.

## 4. Lifecycle

```text
unissued
  └─ authorize one issue → issued, unstarted
       └─ first successful placement → 20-tick construction-period debt-service holiday
            └─ opening period expires → 100-tick serial maturities
                 ├─ payment short → defaulted; arrears/principal remain
                 ├─ full later payment → default clears
                 └─ principal + arrears reach zero → debt-free

reset from any issued or legacy state → unissued
```

### Issuance

`IssueMunicipalBond.execute/2` accepts only a pristine unissued city:

* `municipal_bond == nil`
* tick 0 and revision 0
* no nodes
* money `0.0`
* waste stock `0.0`

Its error union is `:invalid_issue | :not_pristine | :already_financed`. Validation first detects an
existing bond, so a stale second authorization always receives `:already_financed`; it then checks
the issue size and the rest of the pristine-state invariant. Refused commands do not increment
revision.

On success it places `MunicipalBond.new(principal)` on the map and credits the same principal to
`money`. It does not start the construction-period debt-service holiday and does not advance the
tick.

The engine serializes issuance. Two browsers can show the same choices, but only the first accepted
command mutates the city; a later one returns `{:error, :already_financed}` and receives the issued
series through the ordinary metrics broadcast.

### The clock before construction

The engine ignores clock pulses while `municipal_bond == nil` and while an issued bond has
`started_at_tick == nil`. Tick remains 0, no payment or interest accrues, and authorizing the issue
is not a reaction-time test.

The first **successful** placement calls `MunicipalBond.start(bond, city_map.tick)`. A refused click
does not start the opening period. With a start at tick 0:

* transitions producing ticks 1 through 20 require no debt service;
* the transition from tick 20 to tick 21 takes the first payment.

`opening_period_remaining = max(0, 20 - (tick - started_at_tick))`, so the UI reads 20 immediately
after the first placement, 1 at tick 19 and 0 at tick 20. After that,
`maturity_remaining` counts down from 100 to 0 regardless of missed payments.

### Debt-free is not unissued

Redeeming the balance to zero keeps the `MunicipalBond` struct and its original principal. The
issuance screen never reappears, the city cannot authorize another series, and the bond panel can
show the achievement. Only Reset returns to `nil` and permits a new issue.

### Reset

`CityMap.reset/1` still delegates to the one definition of a new city, but that new city now has:

* tick 0;
* revision 0;
* the 2×2 starting grid;
* no nodes;
* money 0;
* waste 0;
* `municipal_bond: nil`.

`CityEngine.reset/1` keeps its delete-before-tick-0-save ordering. It broadcasts the reset map and
new metrics; every connected viewer returns to the issuance choices. The confirmation copy changes
from "start a new city" to "discard this city and authorize a new bond issue" so Reset never
implies another free 400.

## 5. Tick accounting

The payment is **not** another `:money` load.

Money satisfaction drives health only for nodes whose load table contains money. Adding a city-wide
bond to `resources.money.demanded` would make a missed payment decay power plants, water plants,
transit hubs and parks while leaving houses and shops untouched. That is neither a financial rule
nor legible player feedback. It would also make the legend's per-type money rows fail to sum to the
totals row, because no block owns the extra demand.

The money resource remains the operating economy. Debt is a separate boundary flow.

### Exact priority

Each active tick uses this order:

1. Compute health-scaled node income and unscaled node upkeep.
2. Reserve node upkeep, preserving the current invariant that imports cannot make an otherwise
   affordable operating bill fail.
3. Apply scheduled bond service from the post-upkeep balance.
4. Use what remains of the **carried-in treasury** for automatic power, water, waste and labour
   purchases.
5. Advance node health from those final resource statistics.
6. Store the remaining treasury, bond state, landfill and tick.

Current-tick node income may service the bond at the cash boundary. It still may not fund market
purchases until the next tick, preserving the current imported-capacity rule. If
`cash_after_upkeep_and_bond` is the balance after steps 2–3, then:

```elixir
purchase_budget = min(city_map.money, cash_after_upkeep_and_bond)
```

The second term accounts for cash consumed by upkeep and debt; the first preserves the rule that
new income cannot be imported with immediately.

### One shared tick plan

`resource_stats/1`, `advance_tick/1` and `metrics/1` cannot each improvise this ordering.
Extract one private tick-plan calculation in `SimulationCalculator` that returns at least:

```elixir
%{
  resources: resource_stats,
  next_bond: MunicipalBond.t() | nil,
  bond_quote: map() | nil,
  bond_payment: float(),
  cash_after_upkeep_and_bond: float(),
  market_spend: float()
}
```

`advance_tick/1` consumes the transition fields. `metrics/1` reports the quote and resource
statistics without mutating the map. The existing rescue-window projection calls the same
`advance_tick` path, so its countdown automatically includes debt service; no second bond formula
is allowed inside the projection.

Metrics computed immediately after a tick describe the **next** due payment and the market
purchases the current state can support on its next tick. That is already how the metrics panel's
automatic-purchase figure behaves.

## 6. Payment allocation and default

For outstanding principal `P`, original principal `O`, interest arrears `IA`, principal arrears
`PA`, available cash `C`, rate `r = 0.005`, term `T = 100` and servicing tick `n`:

```text
n = tick - started_at_tick - opening_period_ticks + 1
```

The service branch is inactive while `n <= 0`. Thus a tick-0 start produces `n = 1` on the
transition from tick 20 to 21, and `n = 100` on the transition from tick 119 to 120.

```text
current interest  = r × P
interest due      = IA + current interest

current serial    = min(O / T, P - PA) when n < T
                    0                  when n >= T
principal due     = PA + current serial when n < T
                    P                   when n >= T

scheduled due     = interest due + principal due
payment           = min(max(C, 0), scheduled due)
full due covered  = C >= scheduled due

interest paid     = interest due when full due covered
                    min(payment, interest due) otherwise
principal paid    = principal due when full due covered
                    min(P, payment - interest paid) otherwise

next IA           = interest due - interest paid
next P            = P - principal paid

past principal paid    = min(PA, principal paid)                 when n < T
current serial paid    = principal paid - past principal paid   when n < T
next PA                = PA - past principal paid
                         + current serial - current serial paid   when n < T
                         next P                                  when n >= T

defaulted          = next IA > 0 or next PA > 0
```

All subtractions clamp at zero. `C` is a finite float supplied by the calculator. `PA <= P` is an
entity invariant, so `P - PA` is the principal not already past due and a missed maturity is never
scheduled twice. The explicit full-coverage branch assigns the computed amounts rather than
recovering principal by subtracting two floats; the final on-time payment and a full redemption
therefore produce exact zero balances. There is no epsilon and the domain does no display rounding
before allocation.

### Missed principal is not duplicated as arrears

If principal due is not paid, it remains in `outstanding_principal` and is also marked as the
past-due **subset** `principal_arrears`. Paying it reduces both values by the same amount. The next
serial maturity is calculated only from `P - PA`, so arrears make the debt immediately due without
duplicating it. At maturity, every remaining principal amount becomes past due and stays due until
redeemed; the fixed term does not slide forward to disguise a default.

Interest arrears do not earn interest. This avoids exponential debt growth in a browser left open
on a city that can never pay. The bond still becomes harder: every future payment clears accumulated
interest before reducing principal, but the obligation grows linearly while principal is frozen.

### Default consequence

Default is derived, not stored:

```elixir
interest_arrears > 0.0 or principal_arrears > 0.0
```

It means at least one promised interest or principal amount is still past due.

* All cash available after node upkeep was already applied to the payment, so a newly defaulted
  city carries no discretionary balance out of that tick.
* New construction is refused with `:bond_default` until `defaulted?/1` becomes false. Later
  scheduled service or optional redemption can clear the past-due balances. This is the explicit
  enforcement stated in the issue terms.
* Demolition remains available. It can lower upkeep and is already the game's rescue action.
* Optional redemption remains available once call protection has elapsed.
* A later payment clears default only when it clears both kinds of arrears as well as that tick's
  current maturity. At or after final maturity, all remaining principal is in arrears, so default
  clears only when scheduled service or redemption retires the remaining debt.
* Optional redemption can cure default without retiring the whole issue when it clears interest
  and principal arrears; it reduces principal arrears before unmatured principal.

The placement validation order becomes: bounds, known type, occupancy, bond issued, bond not
defaulted, affordability. The first three continue to describe whether the requested cell and type
are meaningful before financing describes whether the command may be funded.

## 7. Optional redemption

The issue becomes callable at par after 20 servicing ticks have elapsed. This call date depends on
simulation time, not successful payment count: a missed payment does not extend it, while a stalled
or stopped clock does. Before then, both actions are visible but disabled with **Callable in N
servicing ticks**. Once callable, the bond panel offers two redemption actions, not a free-form
amount:

```text
servicing ticks elapsed     = max(0, tick - started_at_tick - opening_period_ticks)
call protection remaining  = max(0, 20 - servicing ticks elapsed)
callable                    = servicing ticks elapsed >= 20
```

* **Redeem 25** — available when the redemption amount exceeds 25 and the treasury holds at
  least 25;
* **Redeem all** — available when the treasury covers the exact redemption amount, including
  fractional
  interest arrears.

`RedeemMunicipalBond.execute/2` accepts `:minimum` or `:full`, never a client-supplied float. The use
case derives 25 or exact redemption amount on the server, passes the authoritative map tick, debits
the treasury and applies `MunicipalBond.redeem/3`. This prevents a forged negative or non-finite
amount, enforces call protection on the server and keeps the buttons and command contract
identical.

Its error union contains `:bond_not_issued`, `:legacy_bond`, `:bond_redeemed`, `:not_callable`,
`:use_full_redemption` and `:insufficient_funds`. State is checked before mode, call protection
before affordability, and only a successful debit increments revision. LiveView handles forged or
stale events with explanatory flash copy even though its disabled states prevent them in ordinary
play.

An optional redemption clears interest arrears first, principal arrears second and unmatured
principal last. Reducing principal arrears reduces outstanding principal by the same amount. It
cures default as soon as both arrears balances reach zero, even when unmatured principal remains.
It does not satisfy the next serial maturity in advance; that amount still becomes due on its
scheduled servicing tick. A full redemption assigns all three balances to exact zero.

There is no call premium after the protection period. The protection is load-bearing: without it,
the interest-free construction period would make authorizing 550 and immediately redeeming unused
proceeds dominate the smaller issues. A Generous city must carry its larger debt service through
the first 20 servicing ticks before it can collapse the issue toward Lean or Balanced.

## 8. Solvency, rescue windows and game over

The existing `insolvent` predicate answers an operating question: whether rated node income can
ever cover unscaled node upkeep. Keep that predicate and its `escape` calculation unchanged in
meaning. Debt is temporary and must not make every amortizing city read as permanently insolvent
merely because its full scheduled principal exceeds current surplus.

Bond distress needs a separate derived fact.

### `financing_locked`

Let:

```text
rated operating surplus S = max(0, money_ceiling - node money demand)
```

`financing_locked` is false for a legacy, debt-free, unstarted, construction-period or
call-protected issue. Once the issue is callable, apply the city's remaining treasury optimistically
as an immediate optional redemption: interest arrears first, then outstanding principal, reducing
its past-due subset alongside it. Call the remaining interest arrears and principal `A*` and `P*`.
This is the player's best financial use of cash below the cheapest infrastructure action;
principal arrears are not added again because they are already a subset of `P*`.

The financing is permanently locked when debt remains and:

```text
S <= interest_rate × P*
```

At equality the entire best-case surplus pays new interest, principal never falls and the
treasury never rises. Below it, interest arrears grow. Above it, even a defaulted bond is
recoverable eventually: arrears clear, then some principal is paid, interest declines and the
process accelerates. `A*` matters to whether debt remains, but not to the ongoing comparison;
when `P* == 0`, the same expression correctly says that zero-surplus city cannot clear remaining
arrears while any positive surplus eventually can.

This is an optimistic rated-health bound, like the existing operating insolvency proof. A city is
called terminal only when it fails even at its best possible income.

`SimulationMetrics` gains `financing_locked: boolean()`. Its `game_over?/1` becomes:

```elixir
bankrupt and (stalled or insolvent or financing_locked)
```

Redemption is still an action below the infrastructure bankruptcy threshold, but it cannot change
capacity or demand. The optimistic redemption above is what makes the terminal claim honest: if
even spending every remaining cent on debt cannot move interest below rated surplus, redemption
cannot reopen an infrastructure action.

### Warning before the financing lock becomes unactionable

A finance-locked city with at least 10 may still have an escape: improve operating surplus or
remove upkeep. Before debt service spends that money, the player needs the same kind of warning the
operating insolvency system already provides.

Add `financing_escape` and `financing_rescue_window`:

* enumerate only commands the use case would currently accept: placements on a free cell when the
  issue is not in default, and demolitions of placed nodes;
* for each hypothetical command result, recompute rated operating surplus and apply its remaining
  treasury through the same optimistic redemption used by `financing_locked`;
* the command is a candidate only if debt is then gone or the strict recovery inequality
  `S* > rP*` holds;
* choose the cheapest candidate, or return `{:multiple, Node.cheapest_action_cost()}` when no
  single command proves an escape.

Optional redemption is not a separate escape candidate: `financing_locked` already applies every
available treasury dollar in that best-case order. If that suffices, financing is not locked; if it
does not, a smaller redemption cannot change the proof. Placement candidates remain excluded on a
full grid, preserving the existing escape contract.

The rescue window is an exact forward projection through `advance_tick/1`, stopping when treasury
falls below the selected escape's price, the city stalls, the financing lock clears, or the
existing horizon is reached. It must not divide current cash by current payment: both interest and
principal move.

### Banner precedence

One banner still renders at a time:

1. dead game over (`game_over? and stalled`);
2. locked game over, with operating or financing-specific proof copy;
3. stalled (the clock, opening period and debt service are paused);
4. bond default / financing rescue warning;
5. existing operating rescue warning;
6. none.

Default copy must not claim game over merely because a payment was short. When rated surplus
exceeds interest, a defaulted city can pay the bond more slowly and recover without input.

### Paused time

The existing stalled engine clause remains authoritative: no city tick means no interest, payment,
opening-period countdown or maturity countdown. The same is true after the last viewer leaves and
the engine stops. This is a simulation bond, not a wall-clock subscription.

A stalled player cannot profit from that pause: all nodes are at zero, no income is being produced,
and growth is already halted. Building or a successful demolition restarts ticks and debt service
with them. The bond panel says **Payments paused while the city is stalled**, avoiding a due-next-
tick figure beside a clock that is not moving.

## 9. Metrics and UI

`SimulationMetrics` gains a non-persisted financing summary. The view must not receive the mutable
bond entity and recompute terms itself; the calculator builds the quote:

```elixir
bond: nil | %{
  legacy: boolean(),
  original_principal: float(),
  outstanding_principal: float(),
  interest_arrears: float(),
  principal_arrears: float(),
  redemption_amount: float(),
  opening_period_remaining: non_neg_integer(),
  call_protection_remaining: non_neg_integer(),
  callable: boolean(),
  maturity_remaining: non_neg_integer(),
  next_interest: float(),
  next_principal: float(),
  next_payment: float(),
  defaulted: boolean(),
  paused: boolean()
}
```

It also gains `financing_locked`, `financing_escape` and `financing_rescue_window` beside the
existing operating-solvency fields. `resources.money.demanded`, its satisfaction values and every
`by_type` row remain operating-only.

`SimulationMetrics.financing_warning?/1` mirrors the existing reaction-window predicate: it is true
only when financing is locked, the city is neither stalled nor bankrupt, the bond is not already in
default, and a non-nil financing rescue window is at most the shared 12-tick reaction budget.
Default has its own always-visible banner, so the predicates do not compete.

### Issuance screen

When `@metrics.bond` is `nil`, render a municipal-bond issuance card in place of the interactive
simulator. It uses three real buttons with stable IDs:

* `#issue-bond-250`
* `#issue-bond-400`
* `#issue-bond-550`

Each card shows proceeds now, the construction-period debt-service holiday, first debt service,
20-servicing-tick call protection, fixed maturity, on-time total interest, the strategic role from
§2 and the fact that missed debt service blocks new construction until the past-due amounts are
cleared. Balanced is marked **Recommended** and focused first in DOM order. The copy says plainly:

> Authorize a municipal bond issue to fund the city. No debt service is due for the first 20 ticks
> after construction begins. Then serial principal and 0.5% interest are due each tick, with final
> maturity 100 servicing ticks later. Optional redemption opens after the first 20 servicing ticks.

The page still begins with `<Layouts.app flash={@flash}>`. The issuance controls are server events,
not an inline script or a client-owned form. While a dead render can show the issue choices, their
buttons become actionable only on the connected mount in the ordinary LiveView lifecycle.

### Bond panel

After issuance, a compact `#bond-panel` sits in the always-visible metrics column and shows:

* principal outstanding;
* interest and principal arrears, each only when positive;
* `Debt service begins in N ticks`, `Next debt service X`, `Payments paused`, or `Bond redeemed`;
* `Matures in N ticks` once servicing begins;
* the server-calculated redemption amount;
* `Callable in N servicing ticks` until optional redemption opens;
* `#redeem-bond-25` and `#redeem-bond-full` with affordability and call-protection disabled states
  plus explanatory titles.

Treasury and debt figures use at most two decimal places and never `trunc/1`. A formatted value is
prefixed with `≈` whenever it differs from the underlying float; a positive value below 0.01 renders
as `<0.01`. The Redeem all button sends no displayed number, so formatting can never alter the
exact debit or become a client-supplied settlement quote. Construction and demolition costs remain
whole-number labels.

### Placement affordance during default

Every legend row is visibly unavailable while defaulted even when the treasury happens to cover
its construction cost. Once callable, the cost title reads **bond payment missed — clear the
past-due balance through debt service or redemption before building**. During call protection it
instead reads **bond payment missed — clear the past-due balance through debt service; optional
redemption opens in N servicing ticks**. Type selection remains enabled, as it does for ordinary
unaffordability.

Demolition cells remain clickable and retain their existing affordability rule.

### Legacy cities

A legacy zero-principal record renders no bond panel and no issuance screen. The player keeps
exactly the city and treasury already stored. Reset is visible even on an otherwise untouched
legacy city, because Reset now changes the financing model as well as the grid; after confirmation
it reaches issuance.

Replace the grant-relative `show_reset?/1` rule with the exact financing-aware predicate:

```elixir
metrics.bond != nil or metrics.node_count > 0 or metrics.money != 0.0 or
  metrics.waste_stock != 0.0
```

It is false only for a pristine unissued city. It is true for every legacy or issued city, including
an issued-unstarted city whose treasury still equals its proceeds.

## 10. Persistence and version skew

This feature adds two fields to the persisted `CityMap` and makes a new struct reachable from it. It
therefore hits both persistence hazards documented at the entity and in `docs/deploying.md`:

* an old payload has no `:municipal_bond` key;
* an old payload has no `:revision` key;
* an old binary does not know the new field atoms, the MunicipalBond struct name or its field atoms,
  so `binary_to_term(..., [:safe])` cannot decode a new payload.

### Same-tick durability is a prerequisite

The current repository orders snapshots by simulation tick and refuses an equal tick. Issuance
happens while the clock is frozen at tick 0, and optional redemption is a command rather than a
tick. The promise in §11 that both save immediately is therefore impossible today:

1. Reset deletes the old row and saves an unissued city at tick 0.
2. Issuance changes cash and principal but keeps tick 0.
3. `SnapshotRepository.save/3` sees stored tick 0 and correctly returns `{:stale, 0}`.
4. Closing before construction restores the unissued snapshot and discards the bond.

The same race already exists for a placement or demolition made immediately after a checkpoint;
the bond makes it deterministic because unissued and issued-unstarted clocks intentionally do not
advance.

Add `CityMap.revision`, incremented exactly once by every authoritative mutation:

* issuance;
* successful placement;
* successful demolition;
* an advanced simulation tick;
* optional redemption.

Reset is a new generation: its existing delete happens first and its replacement starts at
`{tick: 0, revision: 0}`. Primitive entity helpers used to assemble fixtures do not increment
revision; use cases increment once around the completed command so a placement that also grows the
grid is one revision, not three.

Snapshot ordering becomes lexicographic `{tick, revision}`. Name this pair `snapshot_order()`. The
port becomes `save(city_id, order, city_map)`, loads `{:ok, {order, city_map}}`, and returns
`{:stale, stored_order}`. The repository refuses a write only when the stored pair is greater than
or equal to the incoming pair. This preserves the crash-and-replay guarantee while allowing
multiple commands between ticks to save durably.

* The port's `load` and stale result carry the ordering pair.
* Postgres gains a non-null `revision` integer defaulted to 0; its locked transaction compares both
  columns.
* The file writer emits a version-2 envelope with `revision`; a version-1 envelope defaults it to
  0, and primary/backup selection uses the pair.
* The payload's `city_map.tick/revision` must match the envelope or columns. Adapters reject a
  mismatch on read or write; they never guess which copy is newer or silently repair one.

Generate the Postgres change with `mix ecto.gen.migration add_revision_to_city_snapshots`, rather
than inventing a timestamp. The migration must be applied before deploying a binary that reads or
writes the new column; this repository's continuous deployment does not run migrations for us.

This is not optional polish. Deleting before every command would punch a hole in monotonic saves,
and incrementing the simulation tick for a financial command would shorten the opening period and
bond maturity when the player clicked a button. Revision is the separate ordering dimension the
model requires.

### Old payload to new code

`SnapshotVocabulary` adds `MunicipalBond` to `@modules`, and `:revision` plus `:municipal_bond` to
`@added_fields`. `modernize/1` uses `Map.put_new(:revision, 0)` and
`Map.put_new(:municipal_bond, MunicipalBond.legacy())` before rewriting nodes.

`CityEngine.normalize_city_map/1` must independently detect whether the stored map had the key
**before** merging it onto `%CityMap{}`. A missing key receives `MunicipalBond.legacy()`; a present
`nil` remains nil. This distinction is load-bearing: blindly merging onto the new struct default
would turn every old saved city into an unissued zero-cash city while preserving its existing
nodes, a state the issuance command correctly refuses and the player cannot repair.

Both committed pre-field fixtures must assert the complete legacy bond, not merely that decoding
succeeds. The cold-VM vocabulary fixture must contain a real active bond with both kinds of arrears
once the writer ships, so every new struct and field atom is exercised under `:safe` decoding.

### New payload to old code

Interning the atoms one release early would prevent a decode crash, but it would not make rollback
semantically safe: an older calculator would treat bond proceeds as a grant and never service the
issue. This is the ring-growth class of hazard, not only the `:safe` atom class.

**Decision: the writer release is the minimum rollback target.** The implementation updates
`docs/deploying.md` with the exact commit once known. Rolling a server or desktop binary behind
that point can either fail decode or silently suspend debt service; neither is supported.

A two-release atom bridge is optional operational hardening but is not represented as a safe
rollback solution. Full safety would require the bridge binary to understand and service future
bond state, which is the feature itself.

## 11. Architecture and command surface

### Domain

* Add `Domain.Entities.MunicipalBond` with all issue terms and arithmetic.
* Change `CityMap`'s new-city default from 400 money to 0 and add `revision: 0` plus
  `municipal_bond: nil`.
* Remove `opening_grant/0`; do not retain a second named starting balance. The value 400 survives
  only as one issue size and as a historical figure in migration documentation.
* `ManageInfrastructure.place/4` starts the construction-period debt-service holiday on the first
  success and adds `:financing_required | :bond_default` to its error union.
* `SimulationMetrics` stores the financing summary and predicates but does not perform bond math.
* `SimulationCalculator` owns tick ordering, the finance-lock proof and both projections.

### Use cases

* Add `IssueMunicipalBond.execute/2`.
* Add `RedeemMunicipalBond.execute/2`.
* Keep persistence out of both; `CityEngine` owns saving and broadcasting.
* `ResetCity` continues returning the new map and metrics, now unissued.

### Infrastructure

`CityEngine` adds synchronous APIs:

```elixir
issue_municipal_bond(city_id, principal)
redeem_municipal_bond(city_id, :minimum | :full)
```

Both execute a use case, recompute metrics, save immediately and broadcast
`{:city_metrics, metrics}`. Immediate saving is required: closing after authorizing an issue but
before the first checkpoint must not return the player to issuance, and closing after an optional
redemption must not restore principal already retired.

No new PubSub message is needed. Metrics contain every financing fact the view needs; adding a
second message would create an ordering race between treasury and principal displays.

The unissued/unstarted tick clauses sit before the stalled clause. All three return the state
unchanged.

### Web

`SimulatorLive` handles the five new button events, the two new placement errors, the financing
command error unions and the bond panel. It does no rate, serial-maturity, redemption or
finance-lock arithmetic.

No external script, stylesheet, dependency or route is added.

## 12. Documentation and generated evidence

`docs/PLAYING.md` must stop describing any money as a grant. Its opening section gains:

* the three issue sizes and terms;
* why the construction-period debt-service holiday starts on first placement;
* the difference between operating money flow and debt service;
* default, optional redemption and paused-time rules;
* the call-protection boundary;
* a Lean route that pauses at the four-block core;
* a Balanced direct route measured through the real payment priority.

The generated blocks change:

* `costs` replaces "A new city starts with 400" with the three authorized issue sizes;
* `opening` runs from `MunicipalBond.recommended_issue/0`, includes scheduled debt service and no
  longer subtracts a grant constant;
* `opening_pace` reports the measured Balanced opening-period/debt-service boundary;
* a new `bonds` block renders the issue/term table from domain constants and measured opening flows.

`PlayingGuide.opening_max_gap_ticks/0` must authorize the Balanced issue through the same domain use
case and advance the real calculator. A helper that merely sets `money: 400` would certify the old
grant under a new heading.

README's opening-economy paragraphs change with the guide. Historical specs remain historical;
do not rewrite their then-current grant figures.

## 13. Verification

### MunicipalBond entity

* all three authorized issue sizes construct; any other value is refused;
* legacy, unissued, issued, defaulted and debt-free states are distinct;
* first placement records the start once;
* ticks 1–20 after a tick-0 start require no debt service and tick 21 takes the first payment;
* each issue's first debt service and 100-payment total match §2;
* the 100th servicing tick makes every remaining principal amount due after an earlier default;
* an on-time issue ends at exactly zero principal and arrears, never a float residue;
* partial cash pays old interest, current interest, past-due principal and the current serial
  maturity in that order;
* unpaid interest grows linearly and is never included in the next interest base;
* unpaid principal remains principal, is marked as a past-due subset and is never scheduled twice;
* optional redemption clears interest arrears, principal arrears and unmatured principal in that
  order and cannot reopen the issue;
* optional redemption is refused through the 20th servicing tick and accepted immediately after;
* default is derived from the two arrears balances and clears exactly when both reach zero.

Every negative assertion gets its positive counterpart first, and each load-bearing test is seen
red by mutating the relevant ordering, boundary or rate.

### Calculator

* node upkeep is paid before debt;
* debt is paid before imports;
* current-tick income can service debt but cannot fund current-tick imports;
* bond service never appears in `resources.money.demanded` or a type row;
* debt can reduce purchases and therefore health on the same tick;
* `resource_stats`, `advance_tick` and metrics use one tick plan;
* operating rescue-window projection includes every future bond transition;
* a stalled city, unissued city and issued-unstarted city change neither tick nor bond;
* a recoverable default with rated surplus above interest eventually clears;
* equality between rated surplus and interest is financing-locked;
* optimistic use of a sub-10 treasury can cross the interest boundary and prevents a false game
  over;
* a case that still cannot cross is game over;
* finance escape excludes placement on a full grid and during default, and evaluates candidate
  commands with the treasury they leave behind;
* financing warning uses the same 12-tick boundary as the operating warning and is suppressed by
  default, stall and bankruptcy.

### Use cases and engine

* issuance credits proceeds exactly once and rejects a second concurrent authorization;
* every financing error returns the specified atom and leaves map and revision unchanged;
* issuance, optional redemption and Reset are saved immediately;
* first successful placement starts the construction-period debt-service holiday; every refused
  placement leaves it unstarted;
* default refuses construction but not demolition;
* reset returns money 0 and financing nil, then broadcasts metrics that open issuance;
* two attached views converge after issuance, redemption, default and reset;
* hydration preserves active, defaulted, redeemed and unissued bond states.

### Persistence

* every pre-bond fixture hydrates debt-free with its exact stored treasury;
* both defaulting paths distinguish an absent key from a present nil;
* a cold VM decodes a maximal active bond with non-zero interest and principal arrears;
* server and file adapters round-trip every bond field and revision;
* an old Postgres row and a version-1 file envelope both load at revision 0;
* two successful same-tick commands save as increasing revisions and hydrate the latter;
* refused commands do not increment revision;
* a stale lower revision at the same tick is refused;
* a higher tick still beats every lower-tick revision;
* deployment documentation names the writer commit as the rollback floor.

### LiveView

Tests use the IDs in §9 and assert outcomes rather than raw HTML:

* a fresh city shows the three issue sizes and no interactive placement grid;
* Balanced is marked recommended and its issue figures are correct;
* issuance dismisses the setup view, credits proceeds and shows 20 opening-period ticks;
* the first placement starts the countdown; a rejected click does not;
* metrics show next debt service, maturity, arrears, redemption, default and redeemed states,
  marking any rounded financial figure as approximate;
* Redeem 25 and Redeem all enable only when the issue is callable and the server-side actions are
  affordable;
* stale or forged redemption events show the matching error without changing treasury or revision;
* default dims construction rows while demolition remains reachable;
* terminal, stalled, default and operating-warning banners obey the precedence in §8;
* Reset returns every connected view to bond issuance, hides its own control there and shows it
  immediately after authorization.

### Player-facing economic invariants

The guide generator and its tests must prove:

* Lean reaches a durable earning city and can eventually complete the opening;
* Balanced completes the documented direct route at a readable pace;
* Generous permits a strictly larger placement gap than Balanced;
* every issue can retire from the documented finished city;
* no issue's warning or default banner fires during its documented route;
* redeeming an issue increases net money flow by exactly the debt service that disappears.

Run targeted files while implementing, then the repository-required `mix precommit`. The feature
is not complete if generated docs, cold-snapshot tests or full-suite fixtures still model a free
grant.

## 14. Accepted consequences and rejected alternatives

### Accepted: the choice is also a difficulty choice

Lean, Balanced and Generous are not equally optimal skins. Lean asks the player to understand the
core and save; Generous forgives more hesitation and taxes later growth. That is the agency the
feature exists to create. The UI says so rather than presenting the cards as neutral financing
products.

### Accepted: active play, not absence, advances the bond

Closing the page pauses debt just as it pauses health, imports, income and waste after the engine
stops. Wall-clock catch-up would require storing timestamps, replaying potentially unbounded ticks
and deciding whether a city can die while nobody is present. This feature does none of those.

### Accepted: default can turn a slow opening into a reset

The 20-tick construction-period debt-service holiday is the clear deadline. After it, a city that
cannot make debt service loses access to new construction until it catches up. Reset is always
available and returns to issuance. This is sharper than the fixed grant, but it is visible before
authorization and produces a specific lesson rather than a silent empty treasury.

### Rejected: add debt to the money resource

It corrupts node health attribution, breaks type totals and hides the payment inside a resource
whose current meaning is operating supply versus upkeep.

### Rejected: coupon-only serial service with a balloon maturity

It makes deferring principal rational until one punitive balloon and fails to create the visible
retirement arc the mechanic promises.

### Rejected: compound unpaid interest

It creates exponential balances in a real-time tab, adds no tactical decision beyond simple
arrears and risks non-finite floats in long-running terminal cities.

### Rejected: arbitrary issue size

It adds false precision before the player understands the economy, expands the balance/test matrix
without adding a qualitatively new strategy, and makes first-screen copy harder to compare. Custom
financing can be reconsidered after the three issues have measured play data.

### Rejected: immediate callability

Calling at par during the interest-free construction period makes Generous strictly dominate: take
the largest buffer, then redeem whatever was not needed before the first interest charge. Twenty
servicing ticks of call protection makes the initial authorization a real commitment while leaving
later principal management in the player's hands.

### Rejected: retain a small free grant beside the bond

It weakens the tradeoff and leaves two definitions of starting money. A new city has zero until it
authorizes a bond issue; legacy cities are the only debt-free exception.

### Rejected: assign current cities the 400 bond issue

Their 400 was presented and balanced as a grant. Turning an already-spent historical benefit into
a liability changes saved state without player action and can immediately lock cities whose
owners never accepted these terms.
