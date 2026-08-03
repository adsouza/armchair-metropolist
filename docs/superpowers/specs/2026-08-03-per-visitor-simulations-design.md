# Per-visitor simulations — design

**Date:** 2026-08-03
**Status:** approved, not yet implemented

## 1. Problem

The deployed web app runs **one** simulation. Every visitor to
`https://armchair-metropolist.gigalixirapp.com` sees the same city, places nodes into the same grid,
and watches the same tick counter. Two people using it at once are editing each other's work, with no
indication that is happening.

That is not a bug in any module — it is what the code says. `CityEngine.snapshot/0` takes no
argument, there is one row-stream in `city_snapshots`, and one PubSub topic carries every delta to
every viewer. The singleton was the right shape for a desktop application, which is what the desktop
target still is. It is the wrong shape for a public URL.

Goal: each visitor gets their own city, backed by their own data, identified by a cookie.

## 2. Measured starting position

The architecture is kinder to this than the problem statement suggests, and it is worth being precise
about why.

**The pure core needs no changes at all.** Every use case already takes a `city_map` and returns a new
one:

| function | signature |
|---|---|
| `UseCases.ManageInfrastructure.place/4` | `(city_map, x, y, type)` |
| `UseCases.ManageInfrastructure.demolish/3` | `(city_map, x, y)` |
| `UseCases.AdvanceCityTick.execute/1` | `(city_map)` |
| `UseCases.SummarizeCity.execute/1` | `(%CityMap{})` |

`Domain`, `Domain.Entities` and `Domain.Services` are the same — they never held identity, so they are
already multi-tenant. This is the hexagonal boundary paying out: the change is confined to adapters.

**The singleton lives in exactly three places:**

| where | what |
|---|---|
| `CityEngine` | `GenServer.call(__MODULE__, …)` — `snapshot/0`, `place/3`, `demolish/2` |
| `CityEngine` | one `@simulation_topic` for every delta |
| `Domain.Ports.SnapshotRepository` | `load_latest/0`, `save/2` — no identity parameter (`snapshot_repository.ex:12,14`) |

**Blast radius:**

| | |
|---|---|
| Production call sites of the engine | **3** — `simulator_live.ex:39`, `:68`, `:78` |
| Test call sites | ~45, all in `city_engine_test.exs` |
| Adapters to follow the port | `SnapshotStore`, `FileSnapshotStore`, plus `StubSnapshotRepository`, `SlowSnapshotRepository`, `SnapshotRepositoryContract` |
| Migrations | one |

**The cookie plumbing already exists and is unused.** `endpoint.ex:7-12` configures a signed cookie
session; `:14-16` already passes `connect_info: [session: @session_options]` to the LiveView socket;
`plug Plug.Session` is at `:49`; the router's `:browser` pipeline runs `:fetch_session`. And
`simulator_live.ex:34` reads `def mount(_params, _session, socket)` — the session is delivered and
discarded.

**Facts corrected while designing this,** because two of them appear as open problems in
`docs/superpowers/2026-07-30-follow-ups.md` and are no longer true:

* **The `tick` tiebreaker exists.** `snapshot_store.ex` orders by `[desc: s.tick, desc: s.id]`. The
  follow-ups doc's "no tiebreaker" limitation has since been fixed.
* **Checksums are verified on read.** Both adapters recompute MD5 and return
  `{:error, :checksum_mismatch}` (`snapshot_store.ex:75-79`, `file_snapshot_store.ex:157-161`).
* **The Postgres adapter does not fall back to an earlier row.** `load_latest/0` is `limit: 1` and
  then decodes; a checksum failure is returned, not stepped over. So append-only buys **no**
  corruption recovery on the server target today — which is what makes §7's move to one row per city
  cost nothing there. The *file* adapter genuinely does have redundancy (primary + backup, unreadable
  ones skipped, highest tick wins) and keeps it, because desktop stays single-city.

## 3. Decisions taken

Four, each chosen deliberately over named alternatives:

| decision | over | because |
|---|---|---|
| **Freeze on disconnect** — an engine runs only while a viewer is connected | fast-forwarding elapsed time on return; ticking everything forever | CPU scales with *concurrent viewers*, not total cities, and an idle server does nothing. Costs the "come back to a grown city" experience. |
| **Cookie plus a visible re-entry code** | cookie alone; real accounts | A cleared cookie otherwise strands a city permanently. Accounts solve it completely but are a separate project. |
| **One row per city, upserted** | append-only plus pruning; a bounded history | Storage becomes O(cities) rather than O(cities × ticks) and pruning stops being needed. Costs nothing in recovery — see §2. |
| **Delete cities untouched for 90 days** | 30 days; never | Bounded retention with a generous window for someone returning after months. |

## 4. Identity and re-entry

**A plug in the `:browser` pipeline.** If `get_session(conn, :city_id)` is absent, generate one and
put it in the session:

```elixir
:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
```

16 bytes, 22 URL-safe characters. The store is already signed, so the client can read the id but not
forge one — which matters because the id *is* the credential.

`SimulatorLive.mount/3` then reads it. Note Plug session keys arrive as **strings**, so the match is
`%{"city_id" => city_id}`, and the clause needs a fallback for the desktop target (§9) where no
browser session exists.

**Re-entry cannot be a LiveView route.** A LiveView has no `conn` and cannot write the session. So
`/c/:code` is a plain controller action: validate the shape, `put_session(:city_id, code)`, redirect
to `/`. The route goes in the `:browser` pipeline before the `live "/"` entry.

Two things that must be explicit, because leaving them to the implementer's judgement would produce
either a crash or a security hole:

* **Shape validation is an allowlist, not a length check.** Accept exactly
  `~r/\A[A-Za-z0-9_-]{22}\z/` and reject everything else with a 404. The code reaches a database
  query and a `Registry` key, so an unbounded or unfiltered string is the wrong thing to forward.
  Ecto parameterises the query and a `Registry` key is just a term, so neither is an injection risk —
  the reason to validate is that a garbage id would otherwise mint a garbage city and a 10 MB path
  would mint a 10 MB registry key.
* **A well-formed code for a city that does not exist yields a new empty city under that id,** not an
  error. That is the same path a first-time visitor takes, so it needs no special handling, and it
  means a mistyped code gives an empty grid rather than a failure page. The alternative — checking
  existence first — buys a nicer error at the cost of a database round trip on every mount and a
  second code path to test.

**The code is shown in the UI** next to the grid, with one line of copy explaining that the city
lives in this browser and the code is how to get back to it elsewhere.

## 5. Engine lifecycle

**Registry and dynamic supervision.** `Application`'s `simulation_children/0` stops starting a
`CityEngine` and starts instead:

* `{Registry, keys: :unique, name: ArmchairMetropolist.Infrastructure.Simulation.CityRegistry}`
* a `DynamicSupervisor` for engines
* `TickServer`, unchanged

An engine registers under `{:via, Registry, {CityRegistry, city_id}}`. The public API becomes
`snapshot/1`, `place/4`, `demolish/3`, each resolving the id and starting the engine on demand.

**The start-on-demand race is free.** `DynamicSupervisor.start_child/2` returning
`{:error, {:already_started, pid}}` is a success for our purposes, so two simultaneous mounts of the
same city need no locking.

**Freeze by monitoring, with a linger.** `SimulatorLive` calls `attach(city_id, self())` when
`connected?(socket)`. The engine `Process.monitor`s each viewer and holds them in a set; on `:DOWN` it
removes one. When the set empties it saves, then arms a **30-second linger timer** before stopping.
The linger is not decoration: a page reload disconnects and reconnects within a second, and without it
every refresh would pay a save, a process death, a restart and a hydrate. A viewer arriving during the
linger cancels it.

**Shutdown still matters.** The engine keeps its 10-second shutdown budget and its `terminate/2`
snapshot write, which is what makes an application stop lose nothing.

## 6. Clock and PubSub

**`TickServer` does not change at all.** It stays one global clock broadcasting `{:tick, n}` on
`"city_tick"` every second, referencing nothing. `CityEngine.init/1` already subscribes to that topic
(`city_engine.ex:112`); with per-city engines, only *live* engines are subscribed, so a frozen city
consumes no CPU. That is the mechanism that makes §3's freeze decision actually deliver — no
scheduling logic, no per-city timers, nothing to get wrong.

One consequence worth stating: every live city shares a tick boundary, so all of them advance in the
same instant. At small numbers that is fine and arguably desirable. If concurrent viewers ever grow
enough for the synchronised thundering herd to matter, staggering is a later change and needs no
rework here.

**Deltas move to a per-city topic.** `@simulation_topic` becomes `CityEngine.topic(city_id)`
→ `"city:#{city_id}"`. The LiveView subscribes to that instead of the global one. Without this change
every visitor would receive every other visitor's deltas — the current bug, merely relocated.

## 7. Persistence

**The port gains identity and loses a misleading name:**

```elixir
@callback load(String.t()) :: {:ok, {non_neg_integer(), CityMap.t()}} | {:error, term()}
@callback save(String.t(), non_neg_integer(), CityMap.t()) :: :ok | {:error, term()}
```

`load_latest` becomes `load`, because with one row per city there is no longer a set to be *latest*
among. Keeping the old name would preserve a claim the storage no longer makes.

**Schema.** A migration that recreates the table keyed on the city:

* `city_id :string`, primary key
* `tick`, `payload`, `checksum` as today
* `timestamps()`, with an index on `updated_at` for the reaper (§8)

`SnapshotStore.save/3` upserts on `city_id`, and the `desc: s.id` tiebreaker disappears along with
the rows it disambiguated.

**But the upsert is guarded, and the refusal is reportable.** An unconditional upsert would be
last-write-wins, which silently drops something the append-only layout provided: ordering on tick
rather than on write time meant a crashed engine that hydrated from an older snapshot could not
overwrite newer work. `docs/superpowers/2026-07-30-follow-ups.md` records that scenario. So the port
is:

```elixir
@callback save(String.t(), non_neg_integer(), CityMap.t()) ::
            :ok | {:stale, non_neg_integer()} | {:error, term()}
```

`{:stale, stored_tick}` means the write was declined because a snapshot at that tick or later is
already stored. It is deliberately not an `{:error, …}`: the engine must log it differently, because a
refusal means the data was *protected* where a failure means it was lost. Both adapters honour it —
the Postgres one by a locked read-then-write inside a transaction (a query-based `on_conflict` would
refuse just as well but could not report having done so), the file one by declining before it rotates
its primary out to backup.

This also keeps the two adapters honouring one contract, which an unconditional upsert would have
broken: `FileSnapshotStore.load/1` reads both its files and takes the higher tick, so it satisfies the
guarantee whatever the write order — the Postgres adapter had to be made to.

**The existing city is preserved, not dropped.** The migration copies the highest-tick existing row
into a well-known city id (`"legacy"`), so whatever has been built on the deployed instance stays
reachable at `/c/legacy` rather than being silently discarded by a schema change. The old rows are
then dropped.

## 8. Retention

A small `SnapshotReaper` GenServer, server target only: on boot, and then every 24 hours, delete rows
whose `updated_at` is older than 90 days. It logs the number deleted — a sweep that removes data
should say so, or nobody will notice when it removes the wrong amount.

Configurable interval and age so tests can drive it directly rather than waiting a day. Gated in
`Application` behind the same style of config flag as the rest of the tree, and absent from the
desktop target, which has exactly one city that must never be reaped.

## 9. Desktop stays single-city

The desktop application has one user and one city, and nothing here should change its behaviour.
`Desktop.Config.apply!/0` pins a constant city id; `FileSnapshotStore` implements the new arity and
ignores the id, continuing to write its primary and backup files. The port's shape changes; the
desktop semantics do not.

`SimulatorLive.mount/3`'s session clause therefore needs the fallback noted in §4 — on desktop there
is no browser session, so it takes the configured id.

## 10. Known limitations, accepted

* **The city code is a bearer token and it appears in a URL.** Anyone holding it has the city.
  `/c/:code` puts it in the address bar, in browser history, and in Phoenix's request logs. 128 bits
  makes it unguessable, not unloggable. Accepted deliberately: the asset is a toy city, and the
  alternatives (a POST form, or scrubbing the path in the logger) buy little at this stake. Revisit if
  anything of value is ever attached to a city.
* **A cleared cookie still loses the city unless the code was saved.** The re-entry code mitigates
  this; it does not remove it, because nothing prompts a visitor to record the code before they need
  it.
* **Two browsers are two cities.** By design. Accounts are the only real fix and are out of scope.
* **A frozen city does not advance.** Someone returning after a week finds their city exactly as they
  left it. This is the §3 decision working as intended, but it is the most likely thing for a user to
  find surprising.
* **All live cities tick simultaneously.** See §6.
* **An engine that cannot start crashes the caller rather than returning an error.**
  `CityEngine.call/3` hard-matches `{:ok, _pid} = CityRegistry.ensure_started(city_id)`, so any
  `DynamicSupervisor.start_child/2` failure other than `{:already_started, pid}` raises a `MatchError`
  in the calling LiveView. Unreachable today — `init/1` only subscribes to PubSub and returns
  `{:continue, :hydrate}`, with no failure path. Deliberately not "fixed": `SimulatorLive` hard-matches
  `{:ok, %{city_map: …}} = snapshot(city_id)` too, so converting this to a clean `{:error, reason}`
  would move the crash rather than remove it, and adding a real error path means designing what the
  page shows when no engine can start — work this plan does not carry. Revisit if `init/1` ever gains
  a way to fail.
* **One row per city means a corrupt row is an unrecoverable city** on the server target. Unchanged
  from today in practice, since `load_latest/0` never fell back either — but the *option* of adding
  fallback disappears with the history.
* **The reaper deletes on `updated_at`, which the linger affects.** A city touched briefly and
  abandoned has its clock reset by the freeze-time save, so 90 days is measured from the last save
  rather than the last human interaction. The difference is at most the linger window and does not
  matter at this granularity.

## 11. Scope and sequencing

One spec, one implementation plan. Sections 4 through 7 are a single coherent change and cannot
usefully be split: identity without per-city engines does nothing, per-city engines without a
per-city port cannot persist, and shipping any two of the three leaves the deployed app in a worse
state than it is now.

**§8's reaper is the exception and should be the last task.** It is independent — the rest works
without it, and it needs the schema from §7 to exist first. If the plan runs long, it is the piece to
defer, at the cost of an unbounded table growing at one row per visitor.

Sizing, against the Linux bundle work that preceded it: comparable. Touches `ArmchairMetropolistWeb`
and `Infrastructure`, adds one migration, and leaves `Domain`, `Domain.Services` and `UseCases`
untouched.

## 12. Verification

The pure core is already covered at 100% and does not change, so the new tests are all about the
adapters and the wiring.

* **Isolation is the headline property, and it needs a test that fails without it.** Two engines with
  different ids, a node placed in one, and the other's snapshot unchanged — plus a subscriber to each
  topic asserting the delta arrives on one and not the other. The second half is the one that would
  catch a forgotten per-city topic, which is the single most likely way this ships broken.
* **Mutation-verify the topic change specifically.** Revert `topic/1` to a constant and confirm the
  isolation test goes red. A test that passes because both subscribers happen to see their own city's
  delta would look identical to one that works.
* **Freeze:** attach a viewer, kill it, and assert the engine saves and stops after the linger.
  Then assert a viewer arriving during the linger cancels it — the case a naive implementation gets
  wrong.
* **Start-on-demand race:** spawn concurrent `snapshot/1` calls for a cold city id and assert exactly
  one engine exists and no caller got an error.
* **The contract module gains the id parameter,** and both real adapters plus both test doubles keep
  passing it. `FileSnapshotStore`'s existing primary/backup recovery cases must still pass unchanged —
  that is the regression test for §9's claim that desktop behaviour is untouched.
* **Migration:** apply it against a database holding the current shape with several rows and assert the
  highest-tick city survives as `"legacy"` and is loadable. Roll back and reapply.
* **Reaper:** a row with a backdated `updated_at` is deleted and a fresh one is not. Run it with the
  age configured to zero and confirm it does not delete a row it just saw — the off-by-one that would
  quietly empty the table.
* **The coverage gate stays at 90%.** New modules — the plug, the controller action, the registry
  wiring, the reaper — all need tests to hold it.
