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
  │  │    Simulation.TickServer   Persistence.FileSnapshot… │  │
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
Exports only `Simulation.CityEngine`, `Persistence.Repo` and `Desktop.Config`.

**`ArmchairMetropolistWeb`** — Endpoint, router, and one LiveView.

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

Two processes, and the split matters:

**`CityEngine`** is a `GenServer` holding the authoritative city.

* It traps exits and does its persisting in `terminate/2`, which is why it carries
  `shutdown: 10_000` — the default 5s can kill it mid-write.
* It hydrates in `handle_continue(:hydrate, …)`, not `init/1`, so a slow snapshot
  read cannot stall the whole supervision tree at boot. `handle_continue` runs
  before any mailbox message, so no command can observe an unhydrated engine.
* It broadcasts **only diffs** on the `"city_simulation"` topic: `{:city_delta,
  delta}` and `{:city_metrics, metrics}` per tick, plus `{:city_node_placed, node}`
  and `{:city_node_removed, id}` for successful commands. Rejected commands
  broadcast nothing.
* It checkpoints every 50 ticks and again on shutdown.

**`TickServer`** is the clock. It broadcasts `{:tick, n}` where `n` counts *clock
pulses since this process started* — a diagnostic number, not the simulation's tick.
`city_map.tick` is the authoritative one and the only one persisted. Confusing the
two is easy and wrong. The clock also never references the engine, so a dead engine
cannot stall it.

## Snapshots

`:erlang.term_to_binary(city_map, [:compressed])` with an MD5 checksum stored
alongside; a mismatch is treated as corruption rather than decoded.

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
