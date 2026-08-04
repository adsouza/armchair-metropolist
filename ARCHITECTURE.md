# Architecture

Clean/Hexagonal, but the point is that it is **enforced by the compiler** rather
than by convention. [`boundary`](https://github.com/sasa1977/boundary) is in
`compilers`, so a dependency pointing the wrong way is a build failure, not a
review comment someone might miss.

```
                    ┌──────────────────────────────────┐
                    │  ArmchairMetropolistWeb          │  LiveView, Endpoint
                    └──────────────┬───────────────────┘
                                   │
  ┌────────────────────────────────┼───────────────────────────┐
  │                                ▼                           │
  │  ┌──────────────────────────────────────────────────────┐  │
  │  │  Infrastructure                                      │  │
  │  │    Simulation.CityEngine   Persistence.SnapshotStore │  │
  │  │    Simulation.CityRegistry Persistence.FileSnapshot… │  │
  │  │    Simulation.TickServer   Persistence.SnapshotReap… │  │
  │  │                            Desktop.TauriNotifier     │  │
  │  └───────────────┬──────────────────────┬───────────────┘  │
  │                  │                      │  implements      │
  │                  ▼                      │                  │
  │  ┌──────────────────────────┐           │                  │
  │  │  UseCases                │           │                  │
  │  │    AdvanceCityTick       │           │                  │
  │  │    ManageInfrastructure  │           │                  │
  │  │    SummarizeCity         │           │                  │
  │  └───────────┬──────────────┘           │                  │
  │              ▼                          │                  │
  │  ┌──────────────────────────┐           │                  │
  │  │  Domain.Services         │           │                  │
  │  │    SimulationCalculator  │           │                  │
  │  └───────────┬──────────────┘           │                  │
  │              ▼                          ▼                  │
  │  ┌────────────────────────────────────────────────────┐    │
  │  │  Domain            type: :strict, deps: []         │    │
  │  │    Entities.{CityMap, Node, SimulationMetrics}     │    │
  │  │    Ports.{SnapshotRepository, Notifier}  ◄─────────┼────┘
  │  └────────────────────────────────────────────────────┘
  └────────────────────────────────────────────────────────────┘
```

Every arrow points inward. `Domain` declares `deps: []` — it depends on nothing at
all, not even Ecto or Phoenix — and the ports it declares are implemented by
`Infrastructure`, which is what inverts the dependency that would otherwise run
outward from the core to the database.

## The layers

**`Domain`** — `type: :strict, deps: []`. Entities and pure functions over them.
`SimulationCalculator.advance_tick/1` returns `{new_city_map, delta}`, where the
delta holds only the nodes whose **display signature** changed. That signature is
deliberately coarse (rounded health plus status), so a stable city produces an empty
delta and broadcasts nothing — the wire cost tracks visible change, not tick count.

`Domain.Services` is a separate top-level boundary rather than a sub-module, which
is what lets `Infrastructure` be barred from it while still using `Domain`.

**`UseCases`** — orchestration. Each is a function from inputs to `{:ok, …}` or
`{:error, reason}`, with no processes and no I/O of its own. `SummarizeCity` exists
because `Infrastructure` cannot reach `Domain.Services`: `CityEngine` physically
cannot call `SimulationCalculator.metrics/1`, so the use case is the legitimate
route in.

**`Infrastructure`** — everything that talks to the outside world: the two snapshot
adapters, the OTP processes that drive the simulation, and the desktop notifier.
Exports only `Simulation.CityEngine`, `Simulation.CityRegistry`, `Persistence.Repo`
and `Desktop.Config`.

**`ArmchairMetropolistWeb`** — Endpoint, router, one LiveView, and the small amount
of plumbing that decides *which* city a request is looking at: `Plugs.EnsureCityId`
mints a code into the session on first request, `CityCode` generates and validates
them, and `CityController` turns `GET /c/:code` into that session plus a redirect.
The code is a credential — 16 random bytes, URL-safe Base64 — so it is generated
from `:crypto.strong_rand_bytes/1` rather than anything derived or sequential.

## Ports and adapters

Two ports, each with two implementations, chosen by config:

| port | web target | desktop target |
|------|-----------|----------------|
| `SnapshotRepository` | `Persistence.SnapshotStore` (Postgres via Ecto) | `Persistence.FileSnapshotStore` (a file under the OS app-data dir) |
| `Notifier` | `Desktop.LogNotifier` | `Desktop.TauriNotifier` (native notification centre) |

Swapping Postgres for a file is a config change, not a code change — which is the
whole return on the indirection, and the reason the desktop app needs no database.

Both snapshot adapters are held to **one shared contract test**
(`test/support/snapshot_repository_contract.ex`), so a second adapter cannot quietly
implement less than the first.

## The simulation

One clock, and one engine per city. The split matters:

**`CityEngine`** is a `GenServer` holding the authoritative city — one process per
`city_id`, not one per node.

* It traps exits and does its persisting in `terminate/2`, which is why it carries
  `shutdown: 10_000` — the default 5s can kill it mid-write.
* It hydrates in `handle_continue(:hydrate, …)`, not `init/1`, so a slow snapshot
  read cannot stall the caller that started it. `handle_continue` runs before any
  mailbox message, so no command can observe an unhydrated engine.
* It broadcasts **only diffs**, on its own `"city:" <> city_id` topic:
  `{:city_delta, delta}` and `{:city_metrics, metrics}` per tick, plus
  `{:city_node_placed, node}` and `{:city_node_removed, id}` for successful
  commands. Rejected commands broadcast nothing. The topic is per city because the
  broadcast carries no city id — one shared topic would have delivered every
  visitor's diffs to every other visitor's LiveView.
* It checkpoints every 50 ticks and again on shutdown.

**`CityRegistry`** names them. A `Registry` maps a `city_id` to its engine via a
`:via` tuple and a `DynamicSupervisor` starts one on demand, so no engine exists
until somebody asks for that city. `ensure_started/1` treats
`{:error, {:already_started, pid}}` as success, which is what makes two simultaneous
mounts of the same city safe without a lock — the loser of the race is handed the
winner's process.

Engines are `restart: :transient` and do not outlive their audience: each monitors
its attached LiveViews, saves the moment the last one goes, and stops `:normal`
after a linger (30s after the last viewer leaves; 2s after hydrating if none ever
attached, so a cookieless GET cannot strand one). `:transient` is what lets that
deliberate stop stick instead of being restarted.

**`TickServer`** is the clock — one, globally, broadcasting `{:tick, n}` on
`"city_tick"` to every engine at once. `n` counts *clock pulses since this process
started*, a diagnostic number, not the simulation's tick; `city_map.tick` is the
authoritative one, is per city, and is the only one persisted. Confusing the two is
easy and wrong. The clock never references any engine, so a dead engine cannot stall
it and an empty registry costs it nothing.

**`SnapshotReaper`** deletes cities untouched for `:snapshot_retention_days` (90),
sweeping on boot and daily after. Server target only — the desktop has exactly one
city, which must never be reaped. Its scheduled sweeps swallow and log failures:
`init/1` re-runs the boot sweep on restart, so an unguarded database hiccup would
exceed the supervisor's `max_restarts` and take the application down over something
that would have fixed itself.

## Snapshots

`:erlang.term_to_binary(city_map, [:compressed])` with an MD5 checksum stored
alongside; a mismatch is treated as corruption rather than decoded.

**One row per `city_id`**, keyed on it. The table used to be append-only, read back
with `order_by: [desc: tick]`, which made a backwards save structurally impossible —
an older snapshot simply lost the ordering. Collapsing it to one row per city removed
that property, so `save/3` now has to state it: a locked read-then-write that returns
`{:stale, stored_tick}` and writes nothing when a snapshot at `tick` or later already
exists. **That is not an error** — it is a crashed engine, hydrated from an older
snapshot, being stopped from overwriting newer work. The guarantee did not change;
what changed is that it is now explicit and reportable rather than a side effect of
the schema.

Decoding uses `binary_to_term(payload, [:safe])`, and `:safe` **refuses to create
atoms**. A snapshot written by one VM therefore cannot be read by a fresh one until
the entity modules are loaded, because their names are the atoms in question — the
job of `Persistence.SnapshotVocabulary`, called before every decode. This was a real
data-loss bug and is covered by the `@tag :cold_vm` test. `:safe` still does its
actual job: rejecting a payload carrying anything unexpected.

## The two build targets

One codebase, two products, differing only in configuration:

* **server** — the `armchair_metropolist` release, Postgres, deployed to Gigalixir.
  See [`docs/deploying.md`](docs/deploying.md).
* **desktop** — the `desktop` release, Burrito-wrapped into a Tauri sidecar, file
  persistence, no database. See [`README.md`](README.md).

`Infrastructure.Desktop.Config.apply!/0`, called from `Application.start/2`, is what
selects the adapters and endpoint settings for the desktop target. The child list in
`Application.start/2` is assembled from config for the same reason, so a target can
leave whole subsystems out — the desktop build starts no `Repo` at all.

## What the compiler will not let you do

Worth knowing before fighting a build failure:

* `Domain` may not reference Ecto, Phoenix, or anything else. `type: :strict` with
  `deps: []`.
* `Infrastructure` may not reference `Domain.Services`. Go through a use case.
* `boundary` violations are **warnings**, so only
  `mix compile --force --warnings-as-errors` fails on them — which is exactly what
  `mix check` runs, and why `--force` is not optional there (boundary only reports
  on modules it recompiles).

And one gap `boundary` cannot close: `GenServer`, `Agent`, `Task` and `Process` live
in the `:elixir` application, which boundary treats as unconditionally allowed. A
`Domain` module could spawn processes and send messages with `deps: []` still
compiling clean. `test/armchair_metropolist/domain/domain_purity_test.exs` closes it
by reading each Domain module's compiled BEAM imports table — see
[`TESTING.md`](TESTING.md).

The design and its deliberate deviations from the original brief are in
[`docs/superpowers/specs/`](docs/superpowers/specs/).
