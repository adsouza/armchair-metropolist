# Armchair Metropolist — City Infrastructure Simulator

**Date:** 2026-07-29
**Status:** Design approved, pending spec review

## 1. Purpose

A real-time, event-driven city infrastructure simulator. A non-blocking OTP engine advances
a simulation tick every second, computing supply/demand and health decay across placed
infrastructure. A Phoenix LiveView dashboard renders the city and updates over WebSocket by
applying per-tick *diffs* rather than re-rendering the grid. State survives restarts via
compressed binary snapshots.

The architecture is Clean/Hexagonal, and the layering is enforced at compile time by the
`boundary` library rather than by convention.

There are **two deployment targets** from one codebase:

- **Server** — Phoenix served over HTTP, snapshots in Postgres via Ecto.
- **Desktop** — the same Phoenix app wrapped in a native Tauri window via `ex_tauri`,
  running on macOS and Linux, with snapshots in a local file.

The two targets differ only in which adapters are configured. `Domain`, `Domain.Services`
and `UseCases` are byte-identical across both, and `boundary` proves it.

## 2. Verified environment

| Component | Version | Verified |
|---|---|---|
| Erlang/OTP | 29 (erts-17.0.4) | installed |
| Elixir | 1.20.2 | installed |
| Phoenix generator | `phx_new` 1.8.9 | installed |
| Postgres | 18.4, running on `:5432` | `pg_isready` OK |
| `boundary` | 0.10.4 (rel. 2024-09-25) | compat spiked on 1.20.2/OTP 29 — works |
| Rust (`rustc`/`cargo`/`rustup`) | present at `/opt/homebrew/bin` | required by `ex_tauri` |
| Zig | **not installed** | only needed for Burrito *cross*-compilation |
| `ex_tauri` | 0.2.0 (rel. 2026-07-12) | see §8 for the risk assessment |
| Host | macOS 26.5, arm64 | |

**Burrito ERTS availability** (probed directly against the `beam-machine-universal` CDN that
Burrito 1.6 actually uses — the `burrito-elixir/erlang-builder` GitHub repo is stale, last
released March 2023):

| OTP | macOS universal | Linux x86_64 |
|---|---|---|
| 29.0.4 (**our local version**) | 404 | 404 |
| 29.0.3 | 200 | — |
| 28.4.2 | 200 | 200 |
| 27.3.4 | 200 | 200 |

`ex_tauri`'s documented requirement of "Elixir >= 1.15 with OTP 27… OTP 28 not yet supported
due to Burrito ERTS availability" is **stale**. 28.x and 29.x are both available. Only our
exact patch release is unbuilt, and §8.4 covers how that is handled.

## 3. Architecture

### 3.1 Layers

```
Domain            pure entities + ports. Zero OTP, zero Ecto, zero Phoenix.
Domain.Services   pure simulation algorithms. Reachable only from UseCases.
UseCases          orchestration. Depends on Domain + Domain.Services.
Infrastructure    OTP processes, Ecto/file/desktop adapters, PubSub. Implements the ports.
…Web              LiveView UI. Depends on UseCases + Domain entities.
```

Dependencies point inward only. `Domain` names the `SnapshotRepository` and `Notifier` ports;
`Infrastructure` implements them. That inversion is the point of the whole structure and it is
compiler-checked.

Two ports, four adapters, selected per deployment target by configuration:

| Port | Server adapter | Desktop adapter |
|---|---|---|
| `SnapshotRepository` | `Persistence.SnapshotStore` (Ecto/Postgres) | `Persistence.FileSnapshotStore` |
| `Notifier` | `Desktop.LogNotifier` | `Desktop.TauriNotifier` (`ex_tauri`) |

### 3.2 Boundary map

```elixir
# lib/armchair_metropolist/domain.ex
use Boundary, type: :strict, deps: [],
  exports: [Entities.CityMap, Entities.Node, Entities.SimulationMetrics,
            Ports.SnapshotRepository, Ports.Notifier]

# lib/armchair_metropolist/domain/services.ex
use Boundary, top_level?: true, type: :strict,
  deps: [ArmchairMetropolist.Domain],
  exports: [SimulationCalculator]

# lib/armchair_metropolist/use_cases.ex
use Boundary, deps: [ArmchairMetropolist.Domain, ArmchairMetropolist.Domain.Services],
  exports: :all

# lib/armchair_metropolist/infrastructure.ex
use Boundary,
  deps: [ArmchairMetropolist.Domain, ArmchairMetropolist.UseCases,
         Ecto, Ecto.Query, Ecto.Changeset, Ecto.Schema, Phoenix.PubSub, ExTauri],
  exports: [Simulation.CityEngine, Persistence.Repo]

# lib/armchair_metropolist_web.ex
use Boundary,
  deps: [ArmchairMetropolist.Domain, ArmchairMetropolist.UseCases,
         ArmchairMetropolist.Infrastructure, Phoenix, Phoenix.LiveView, Phoenix.PubSub],
  exports: [Endpoint, Telemetry]

# lib/armchair_metropolist/application.ex
use Boundary, top_level?: true,
  deps: [ArmchairMetropolist.Domain, ArmchairMetropolist.Domain.Services,
         ArmchairMetropolist.UseCases, ArmchairMetropolist.Infrastructure,
         ArmchairMetropolistWeb, ExTauri]
```

`ExTauri` appears in exactly two places: `Infrastructure` (for the `TauriNotifier` adapter)
and `Application` (because `mix ex_tauri.install` adds its shutdown manager to the
supervision tree). It appears in **neither** `Domain`, `Domain.Services`, `UseCases`, nor
`…Web` — so if `ex_tauri` is ever swapped for `elixirkit`, the blast radius is the two
modules named in §6.6 and §6.7, and the compiler will refuse to let that leak further.

`mix.exs`:

```elixir
compilers: [:boundary] ++ Mix.compilers(),
boundary: [default: [check: [apps: [
  :ecto, :ecto_sql, :phoenix, :phoenix_live_view, :phoenix_pubsub,
  :postgrex, {:mix, :runtime}
]]]]
```

`top_level?: true` on `Domain.Services` promotes a namespace-nested module to a *peer*
boundary. That is what allows `deps` on it to be granted to `UseCases` and withheld from
`Web` — exports alone are global and could not express this.

### 3.3 What enforcement actually covers

Empirically spiked on this toolchain, not assumed:

| Violation | Enforced by | Result |
|---|---|---|
| Domain calls Ecto / Phoenix | `boundary` | `forbidden reference` |
| Domain → Infrastructure (reverse dep) | `boundary` | `forbidden reference` |
| Any layer touches a non-exported module | `boundary` | `is not exported by its owner boundary` |
| Web → `SimulationCalculator` | `boundary` | `forbidden reference` |
| Domain calls `GenServer`/`Agent`/`Task`/`Process`/`:ets` | **`boundary` does NOT catch this** | see below |

`GenServer`, `Agent`, `Task` and `Process` belong to the `:elixir` application, which
`boundary` treats as unconditionally allowed. `type: :strict` does not help, and neither does
`check: [apps: [:elixir]]` with an explicit module allowlist — both were tried and all five
OTP calls compiled clean.

The gap is closed by `test/armchair_metropolist/domain/domain_purity_test.exs`, which reads
each Domain module's BEAM **imports table** via `:beam_lib.chunks(path, [:imports])` and
asserts no reachable call to `GenServer`, `Agent`, `Task`, `Process`, `Supervisor`, `:ets`,
`:timer`, `:gen_server`, `Ecto.*` or `Phoenix.*`. Because it inspects the compiled dispatch
table rather than source text, aliases, imports and macro-generated calls cannot evade it.
Prototype output:

```
Spike.Domain.Calc -> Agent.start_link/1
Spike.Domain.Calc -> GenServer.call/2
Spike.Domain.Calc -> Process.send_after/3
Spike.Domain.Calc -> Task.async/1
Spike.Domain.Calc -> :ets.new/2
```

Boundary violations are **warnings, not errors**. `mix compile --warnings-as-errors` exits
non-zero on a violation, so that flag is mandatory in the `mix check` alias and in CI;
without it a violation still ships.

## 4. Domain layer

### 4.1 Entities

```elixir
%Node{
  id: "12:7",          # "x:y" — also the LiveView stream DOM id
  x: 12, y: 7,
  type: :power_plant,
  health: 100.0,       # float, 0.0..100.0
  status: :online      # :online | :degraded | :offline — derived from health
}

%CityMap{
  width: 40, height: 30,
  tick: 0,
  nodes: %{"12:7" => %Node{}}   # keyed by id
}

%SimulationMetrics{
  tick: 0,
  resources: %{power: %{supplied: 120.0, demanded: 63.0, deficit: 0.0, satisfaction: 1.0}, …},
  node_count: 5, avg_health: 98.4, offline_count: 0
}
```

### 4.2 Resources and node types

Four resources: `:power`, `:water`, `:waste`, `:traffic`. `waste` models processing
*capacity* against waste *produced*; `traffic` models transit capacity against trips generated.
Every resource is therefore a uniform supply/demand pair:
`supply(r) = Σ production[r]`, `demand(r) = Σ consumption[r]`.

| type | produces | consumes |
|---|---|---|
| `:power_plant` | power 120 | water 20, waste 12, traffic 3 |
| `:water_plant` | water 100 | power 25, waste 6, traffic 2 |
| `:industrial` | waste 90 | power 40, water 25, traffic 8 |
| `:road_hub` | traffic 60 | power 8, waste 2 |
| `:residential` | — | power 15, water 12, waste 10, traffic 6 |
| `:commercial` | — | power 22, water 8, waste 14, traffic 9 |
| `:park` | waste 8 | water 18, traffic 2 |

Every type consumes at least one resource, so the decay rule below is always defined.
`:park` is a mild waste sink but a heavy water consumer, which creates genuine placement
tension rather than a strictly dominant build order.

**Baseline municipal capacity** — a constant `%{power: 40, water: 40, waste: 40, traffic: 40}`
is added to supply, representing pre-existing city services. Without it the very first
building placed on an empty grid starves instantly (nothing supplies `waste`), which is
punishing and reads as a bug. With it, roughly two residential blocks are sustainable before
the player must build utilities — a deliberate on-ramp.

### 4.3 Decay model

All pure, in `Domain.Services.SimulationCalculator`.

- **Effective production** scales by condition: `production[r] * health / 100`.
  Consumption stays at full — broken infrastructure still demands. This asymmetry is what
  produces cascading failure: a power plant degrading reduces power, which degrades more
  nodes, which reduces supply further.
- **Satisfaction** per resource: `min(1.0, supply / demand)`, and `1.0` when `demand == 0`.
- **Health delta** per node, driven by the *worst* satisfaction among the resources it
  consumes:
  ```
  worst = min(satisfaction[r] for r in consumption(node))
  delta = if worst >= 1.0, do: +1.0, else: -(1.0 - worst) * 6.0
  health = clamp(health + delta, 0.0, 100.0)
  ```
- **Status** derives from health, with half-open intervals so the boundaries are unambiguous:
  `:online` when `health >= 60.0`, `:degraded` when `20.0 <= health < 60.0`,
  `:offline` when `health < 20.0`.

### 4.4 Delta semantics

`advance_tick/1` returns `{new_city_map, delta_nodes}` where `delta_nodes` is a map of
`id => Node` containing only nodes whose state changed.

Membership is decided by `Node.display_signature/1` → `{round(health), status}`, **not** by
raw struct equality. This is the crux of the optimisation: `health` is a float that moves
every tick, so raw comparison puts every node in the delta every tick and the diff is
worthless. Comparing display-significant state instead means a saturated healthy city emits
**empty** deltas, and a stressed city emits diffs only for the stressed nodes.

Node *removal* cannot be expressed as an upsert, so demolition is a separate PubSub message
(§6.4) rather than a sentinel value inside the delta map.

### 4.5 Ports

```elixir
defmodule ArmchairMetropolist.Domain.Ports.SnapshotRepository do
  @callback load_latest() ::
    {:ok, {tick :: non_neg_integer(), CityMap.t()}} | {:error, :not_found | term()}
  @callback save(tick :: non_neg_integer(), CityMap.t()) :: :ok | {:error, term()}
end

defmodule ArmchairMetropolist.Domain.Ports.Notifier do
  @callback notify(title :: String.t(), body :: String.t()) :: :ok | {:error, term()}
end
```

The `SnapshotRepository` port speaks `CityMap` only. `:erlang.term_to_binary/2` and the MD5
checksum are serialisation concerns and live entirely in the adapter — if `binary` or
`checksum` appeared in a callback signature, the domain would have learned about storage
encoding and the boundary would have leaked.

`save/2` returns bare `:ok`, **not** `{:ok, id}`. An earlier draft of this spec returned a
row id, which was a Postgres detail leaking through the port: a file adapter has no row id to
return. Designing the second adapter is what exposed it — which is the ordinary way port
leaks get found, and a good argument for writing the second adapter early rather than late.

`Notifier` exists so the desktop shell can be swapped without touching anything above
`Infrastructure`. It is a behaviour with no dependencies, so `Domain` stays `type: :strict`
with `deps: []` and the purity test of §3.3 continues to pass.

## 5. Use cases

- `AdvanceCityTick.execute(city_map)` → `{:ok, %{city_map:, delta:, metrics:}}`
- `ManageInfrastructure.place(city_map, x, y, type)` →
  `{:ok, {city_map, node}} | {:error, :out_of_bounds | :occupied | :unknown_type}`
- `ManageInfrastructure.demolish(city_map, x, y)` →
  `{:ok, {city_map, node_id}} | {:error, :empty}`

## 6. Infrastructure

### 6.1 Schema and migration (server target only)

`priv/repo/migrations/20260729110000_create_city_snapshots.exs` creates `city_snapshots`:

| column | type | notes |
|---|---|---|
| `tick` | `integer` | not null |
| `payload` | `binary` | not null, compressed `term_to_binary` |
| `checksum` | `string` | not null, MD5 of payload, hex |
| `inserted_at`/`updated_at` | `utc_datetime_usec` | |

Index on `tick` descending, for the latest-snapshot lookup.

### 6.2 `SnapshotStore` — server adapter (Ecto/Postgres)

Implements `SnapshotRepository`. Used by the server target only; the desktop target uses
§6.6 instead.

- `save/2`: `:erlang.term_to_binary(city_map, [:compressed])`, then
  `:crypto.hash(:md5, payload) |> Base.encode16()`, insert.
- `load_latest/0`: newest row by `tick`; recompute the MD5 and compare before deserialising;
  return `{:error, :checksum_mismatch}` on mismatch. Deserialise with
  `:erlang.binary_to_term(payload, [:safe])`.

### 6.3 `TickServer` (clock only)

A `GenServer` whose sole job is time. `Process.send_after(self(), :tick, 1000)`, incrementing
a counter and broadcasting `{:tick, n}` on the internal `"city_tick"` topic. It never
references the engine. A slow or crashed engine therefore cannot stall or crash the clock,
and additional tick consumers can be added later without touching it.

**Tick ownership.** There are deliberately two counters and only one of them is
authoritative. `TickServer`'s `n` counts clock pulses since the clock started; it exists for
ordering and diagnostics, and the engine does **not** derive state from it. The authoritative
simulation tick is `city_map.tick`, incremented by `SimulationCalculator.advance_tick/1` and
persisted in snapshots — so it survives restarts, whereas `n` resets to zero whenever
`TickServer` restarts. Everything user-visible and everything written to Postgres uses
`city_map.tick`.

### 6.4 `CityEngine`

`GenServer`, registered by name.

- `init/1`: `Process.flag(:trap_exit, true)`, subscribe to `"city_tick"`, then
  `{:ok, state, {:continue, :hydrate}}`.
- `handle_continue(:hydrate, …)`: `repository().load_latest()`, falling back to
  `CityMap.new(40, 30)` on `{:error, :not_found}`.
- `handle_info({:tick, n}, …)`: delegate to `AdvanceCityTick.execute/1`, store the new map,
  broadcast `{:city_delta, delta}` and `{:city_metrics, metrics}` on `"city_simulation"`,
  and checkpoint when `tick > 0 and rem(tick, 50) == 0`.
- `handle_call({:place, x, y, type}, …)` / `{:demolish, x, y}`: delegate to
  `ManageInfrastructure`, broadcast `{:city_node_placed, node}` or
  `{:city_node_removed, id}`.
- `handle_call(:snapshot, …)`: returns the current map + metrics, for LiveView mount.
- `terminate/2`: synchronous `repository().save/2`.

`trap_exit` is load-bearing, not decoration: a GenServer not trapping exits dies immediately
on the supervisor's exit signal and `terminate/2` never runs. The child spec also sets
`shutdown: 10_000`, because the 5s default can kill the process mid-write and make the
graceful-shutdown guarantee false.

The repository module is read from application config
(`Application.get_env(:armchair_metropolist, :snapshot_repository, SnapshotStore)`), which is
how the port gets injected and how tests substitute a stub.

**Durability.** `terminate/2` covers graceful shutdown but does *not* run on `:brutal_kill`,
VM crash, SIGKILL, or an unhandled crash in a callback. The periodic checkpoint every 50
ticks bounds worst-case loss to 50 ticks instead of the entire session. Both paths share one
write function. The checkpoint write is synchronous inside `handle_info`; at a 1s tick and
one write per 50 ticks this is not a throughput concern, and it avoids the write-ordering
races an async write would introduce.

### 6.5 Supervision tree

```
Infrastructure.Persistence.Repo
{Phoenix.PubSub, name: ArmchairMetropolist.PubSub}
{Infrastructure.Simulation.CityEngine, []}    # shutdown: 10_000
{Infrastructure.Simulation.TickServer, []}
ArmchairMetropolistWeb.Endpoint
```

`Repo` lives at `Infrastructure.Persistence.Repo`, not the Phoenix-default
`ArmchairMetropolist.Repo`, so it sits inside the boundary that owns persistence.

On the **desktop** target `Repo` is omitted from the children entirely — there is no database
process, because the file adapter needs none. `Application.start/2` builds the child list from
config rather than hardcoding it.

### 6.6 `FileSnapshotStore` — desktop adapter

Implements the same `SnapshotRepository` port with no database and no NIF.

The snapshot is *already* a compressed binary blob with an MD5 checksum, so the file adapter
adds only an envelope and safe write semantics:

```elixir
envelope = %{version: 1, tick: tick, checksum: checksum, payload: payload}
```

- `save/2`: build `payload` and `checksum` exactly as §6.2 does, write
  `:erlang.term_to_binary(envelope)` (uncompressed — `payload` is already compressed) to
  `snapshot.tmp`, then `File.rename/2` into place. Rename is atomic on POSIX, so a crash
  mid-write can never leave a torn primary file. Any existing primary is moved to
  `snapshot.bak` first.
- `load_latest/0`: read the primary, `:erlang.binary_to_term(data, [:safe])`, verify the MD5
  against `payload`, then deserialise `payload`. On **any** failure — missing, unreadable,
  malformed envelope, or checksum mismatch — fall back to `snapshot.bak` and try again.
  Return `{:error, :not_found}` only when neither file yields a valid snapshot.

The `.bak` fallback matters because checksum verification without it can only *detect*
corruption while still losing the city. For a single-player game save, one generation of
history is cheap insurance.

The storage directory comes from config (`:snapshot_dir`), not from `ExTauri`. Persistence
must not depend on the shell, so `config/runtime.exs` is what calls
`ExTauri.Paths.data_dir()` on the desktop target and passes the result in.

**This adapter also deletes a whole problem.** `ex_tauri`'s docs warn that desktop releases
do not run migrations automatically and require a bespoke release module to do it at startup.
With no database on desktop, there are no migrations to run, and that entire failure mode
disappears.

### 6.7 `TauriNotifier` and `LogNotifier`

Two adapters for the `Notifier` port. `TauriNotifier` delegates to `ex_tauri`'s notification
API; `LogNotifier` writes to the Logger and is the default for the server target and for
tests. `CityEngine` resolves the notifier from config exactly as it resolves the repository,
and uses it for one thing: announcing when the city first enters a critical deficit.

These two modules, plus one line each in the `Infrastructure` and `Application` boundary
`deps`, are the *entire* surface area of the desktop shell dependency.

## 7. Web layer — `SimulatorLive`

- **Background grid**: 40 × 30 = 1,200 cells rendered by a plain comprehension. Static,
  never re-diffed.
- **Infrastructure**: `stream(:nodes, nodes)`, DOM id = `Node.id`.
- `handle_info({:city_delta, delta})` → `stream_insert/3` per changed node.
- `handle_info({:city_node_placed, node})` → `stream_insert/3`.
- `handle_info({:city_node_removed, id})` → `stream_delete_by_dom_id/3`.
- `handle_info({:city_metrics, m})` → `assign`, driving a per-resource supply/demand readout.
- `handle_event("cell_click", %{"x" =>, "y" =>})` → place the currently selected type.
- A type picker for the seven node types, and a demolish mode.

Only changed nodes cross the WebSocket, and unchanged cells are never re-rendered.

## 8. Desktop packaging — `ex_tauri`

### 8.1 Architecture

`ex_tauri` uses a **sidecar** model: Tauri owns the native window and launches the Phoenix
release as a child process, then points its webview at the local Phoenix server. The webview
is WKWebView on macOS and WebKitGTK on Linux; both support WebSockets, so LiveView works
unmodified. Burrito bundles the BEAM and the application into a single executable per
platform.

In production the app binds to an **OS-assigned free port**, injected into the sidecar via the
`PORT` environment variable, alongside `SECRET_KEY_BASE`, `PHX_SERVER` and `PHX_HOST`. There
is no fixed port to collide with.

The native API bridge is LiveView-only, which suits us — the dashboard is LiveView.

### 8.2 Setup

`mix ex_tauri.install` is a one-time scaffold that writes config, the Tauri project
structure, the release config, a JS hook and layout changes, and installs the Tauri CLI via
Cargo. Configuration:

```elixir
config :ex_tauri,
  version: "2.5.1",
  app_name: "Armchair Metropolist",
  host: "localhost",
  window_title: "Armchair Metropolist",
  width: 1280, height: 900,
  resize: true
```

`mix.exs` also needs `extra_applications: [:logger, :runtime_tools, :inets]`, and
`cache_static_manifest` must be removed from `config/prod.exs` unless `mix assets.deploy` runs
as part of the build (it will).

Mix tasks: `ex_tauri.install`, `ex_tauri.dev` (native window with live reload),
`ex_tauri.build` (production bundles), `ex_tauri.add` (Tauri plugins).

### 8.3 Shutdown and durability

This is the part that interacts with our persistence design, so it is worth being precise.

The Rust side opens a local socket (Unix domain socket on macOS/Linux) and sends a byte every
100ms. A `ShutdownManager` in the BEAM checks every 500ms, and after 1500ms without a
heartbeat begins a **graceful** shutdown: Phoenix closes connections, logs flush, and the node
exits cleanly. `ex_tauri` documents that this holds *"even when the app is force-quit, crashes,
or is killed unexpectedly."*

Graceful means `CityEngine.terminate/2` runs, so the snapshot-on-shutdown guarantee of §6.4
survives the desktop target. Two consequences:

1. Worst-case staleness on window close is roughly the 1500ms heartbeat timeout plus the write
   itself — at a 1s tick, one or two ticks. Acceptable.
2. The heartbeat is a watchdog, not a guarantee. A SIGKILL of the BEAM itself still bypasses
   `terminate/2`, which is exactly why the 50-tick periodic checkpoint from §6.4 stays in
   place on desktop as well. The two mechanisms are complementary, and neither is sufficient
   alone.

### 8.4 Build targets and the OTP pin

```elixir
releases: [
  desktop: [
    steps: [:assemble, &Burrito.wrap/1],
    burrito: [targets: [
      macos_arm: [os: :darwin, cpu: :aarch64],
      linux_x86: [os: :linux, cpu: :x86_64],
      linux_arm: [os: :linux, cpu: :aarch64]
    ]]
  ]
]
```

Our local OTP 29.0.4 has no prebuilt ERTS on the CDN (§2). This does **not** block
development, because Burrito is only invoked by `mix ex_tauri.build` — `mix ex_tauri.dev`
needs Rust alone, which is already installed. Development proceeds on 29.0.4 immediately.

For production builds, in preference order:

1. Pin the build toolchain to **OTP 28.4.2**, which has prebuilt ERTS for macOS *and* both
   Linux architectures, and is a maturer target than 29.x.
2. Failing that, OTP 29.0.3 for macOS.
3. Last resort, Burrito's `custom_erts` option pointing at a locally built ERTS tarball.

**Build each platform on its own platform** in CI (a macOS runner and an Ubuntu runner) rather
than cross-compiling. `ex_tauri` documents Zig as needed only for cross-compilation, so a
per-platform matrix avoids installing Zig 0.16 and sidesteps cross-compilation entirely. This
is to be confirmed on first build rather than assumed.

### 8.5 Risk assessment

`ex_tauri` 0.2.0 was released 2026-07-12 with 138 all-time downloads. It is the right choice
— it explicitly documents the macOS and Linux packaging this project needs, and it means
writing no Rust — but it is young enough that rough edges should be expected, and its own
documentation is already stale on OTP support (§2).

The mitigation is structural, not hopeful. Every `ex_tauri` call sits behind the `Notifier`
port in one adapter module, and `boundary` bars `ExTauri` from `Domain`, `Domain.Services`,
`UseCases` and `…Web`. If `ex_tauri` proves unworkable, the fallback is the `elixirkit`
approach — a plain `mix release` inside a hand-rolled Tauri shell, which also avoids Burrito
and the ERTS-version question altogether — and it costs one new adapter plus packaging work,
not a rewrite.

Consequently the implementation is **phased**: the server target ships and passes its full
test suite before the desktop wrap begins. The riskiest dependency is therefore the last thing
integrated, and a failure there leaves a working application rather than a blocked one.

## 9. Tooling

`mix check` alias, and the same sequence in CI. The `test` alias is the one `phx.new`
generates (`ecto.create --quiet`, `ecto.migrate --quiet`, `test`), so the database is
prepared as part of the run:

```elixir
check: ["compile --force --warnings-as-errors", "test --cover"]
```

`--force` matters: `boundary` only reports violations for modules it actually recompiles, so
an incremental compile can silently pass a violation that a clean compile would catch.

Coverage is gated natively by Mix — no `excoveralls` dependency:

```elixir
test_coverage: [threshold: 90]
```

`mix test --cover` exits non-zero below the threshold. 90% is the floor for the project as a
whole; `Domain`, `Domain.Services` and `UseCases` should sit at or very near 100% by
construction, since they are pure functions with no unreachable I/O branches. If those layers
are *not* near 100%, that is evidence of an untested branch rather than of an untestable one.

Test-only dependency: `{:stream_data, "~> 1.4", only: [:test]}` for the property tests of
§10.6. Test files live outside `lib/`, so they are not subject to `boundary` checks.

`boundary` ships `mix boundary.spec`, `mix boundary.visualize` and
`mix boundary.find_external_deps` for inspecting the enforced graph.

## 10. Testing strategy

### 10.1 Principles

Test-driven, using the `test-driven-development` skill. The purity constraint pays off
directly: **every test in §10.2–10.7 runs with no database, no processes, no PubSub, and
`async: true`.** Nothing in the domain or use-case layers requires a test double.

That last point is worth stating explicitly because it is a design check, not just a
convenience. `AdvanceCityTick.execute/1` and `ManageInfrastructure.place/4` take a `CityMap`
and return a `CityMap` (§5) — they touch no repository. The `SnapshotRepository` stub is
needed only by `CityEngine`, which is infrastructure. **If writing a use-case test ever
requires a stub, orchestration and persistence have become tangled and the design has
regressed.**

### 10.2 `Node`

- `production/1` and `consumption/1` return the documented table (§4.2) for all seven types.
- **Every type consumes at least one resource** — guards the invariant that §4.3's decay rule
  depends on; if a future node type consumes nothing, `Enum.min/1` over an empty list would
  raise.
- `new/3` yields `health: 100.0`, `status: :online`, `id: "x:y"`.
- `status/1` at exactly `100.0`, `60.0`, `59.9`, `20.0`, `19.9`, `0.0` — pinning the half-open
  intervals of §4.3.
- `display_signature/1` returns `{round(health), status}`.

### 10.3 `CityMap`

- `new/2` sets width/height, `tick: 0`, empty `nodes`.
- `in_bounds?/3` true at `(0,0)` and `(width-1, height-1)`; false at `(-1,0)`, `(0,-1)`,
  `(width,0)`, `(0,height)`.
- `put_node/2`, `delete_node/2`, `get_node/2` (hit and miss), `occupied?/2` (both).

### 10.4 `SimulationMetrics`

- Per-resource `supplied` / `demanded` / `deficit` / `satisfaction` aggregation.
- `deficit` is `0.0` on surplus, and `demand - supply` on shortfall.
- `node_count`, `avg_health`, `offline_count`.
- **`avg_health` on an empty city.** This is a division by zero, and an empty grid is the
  *default startup state* (§6.4 hydration fallback) — so it is the first bug this codebase
  would otherwise ship. Must return `0.0`, not raise.

### 10.5 `SimulationCalculator`

Arithmetic:

- Satisfaction capped at `1.0` on surplus; equal to the ratio on shortfall; `1.0` when demand
  is zero.
- Baseline municipal capacity (§4.2) is included in supply.
- Effective production scales by `health / 100`.
- **Consumption does *not* scale with health.** This asymmetry is the mechanism behind
  cascading failure; if both scaled, the simulation would quietly self-stabilise and the
  cascade test below would pass for the wrong reason.
- Regen is `+1.0` at full satisfaction; decay is `-(1.0 - worst) * 6.0`.
- Health clamps at `100.0` (no overflow above) and `0.0` (never negative).
- `worst_ratio` is computed over **only the resources the node consumes** — a `:park`
  consumes no power, so a total blackout must leave it unaffected.
- `tick` increments by exactly one.
- A node at `health < 20` produces effectively nothing.
- **Cascading failure**: seed a city dependent on one power plant, degrade it, and assert over
  successive ticks that power supply falls and other nodes degrade in turn.

Delta semantics — these four are the tests that prove the §4.4 optimisation is real:

| Scenario | Expected |
|---|---|
| Stable, fully-supplied, full-health city | delta is **empty** |
| Starved city | delta contains **only** the starved nodes |
| Health moves `87.3 → 87.8` (same rounded value) | node is **excluded** |
| Status flips while rounded health is unchanged | node is **included** |

The third row is the single most important test in the suite. Without it, `display_signature`
is effectively untested and a naive struct comparison would satisfy every other assertion here
while emitting a full-grid delta every tick.

Determinism: `advance_tick/1` applied twice to identical input produces identical output.

### 10.6 Domain properties (`stream_data`)

Generated over arbitrary city compositions and tick counts, asserting invariants that
example-based tests can only sample:

- `health` remains within `[0.0, 100.0]` after any number of ticks.
- `delta` keys are always a subset of the city's node ids.
- `delta` contains **exactly** the nodes whose `display_signature/1` changed, verified by
  recomputing signatures before and after rather than by trusting the implementation.
- `advance_tick/1` is deterministic for any generated city.
- `tick` strictly increases.
- `advance_tick/1` neither creates nor destroys nodes — `node_count` is invariant.
- `place/4` followed by `demolish/3` at the same coordinates round-trips to the original map.

### 10.7 Domain purity

`domain_purity_test` — the BEAM imports-table assertion of §3.3, covering the enforcement gap
`boundary` cannot close.

### 10.8 Use cases

`AdvanceCityTick` — returns `{:ok, %{city_map:, delta:, metrics:}}`; tick incremented; metrics
consistent with the returned map; the delta matches the calculator's; **an empty city advances
without raising** (see §10.4).

`ManageInfrastructure` — `place/4` succeeds with a node at `100.0`/`:online` at the requested
coordinates; rejects `(-1,y)`, `(x,-1)`, `(width,y)`, `(x,height)` with `:out_of_bounds`;
rejects an occupied cell with `:occupied`; rejects an unrecognised type with `:unknown_type`;
leaves all other nodes untouched. `demolish/3` returns the removed id, removes exactly one
node, and returns `:empty` for a vacant cell.

### 10.9 Infrastructure

`snapshot_store_test` against the real Postgres 18: round-trip, latest-wins selection, and a
**corrupted-checksum** case asserting `{:error, :checksum_mismatch}`. `city_engine_test`
covering hydration from a seeded snapshot, fallback to an empty grid, delta broadcast on tick,
and `terminate/2` persistence — using the in-memory `SnapshotRepository` stub, which lives
here rather than in the use-case tests. `tick_server_test` asserting the clock broadcasts and
does not reference the engine.

### 10.10 Web

`simulator_live_test`: mount renders the grid, a broadcast delta updates only the affected
node, click places infrastructure.

### 10.11 Desktop adapters

`file_snapshot_store_test` against a per-test temp directory:
round-trip; corrupt the primary file's checksum and assert fallback to `.bak`; corrupt both
and assert `{:error, :not_found}`; assert no `snapshot.tmp` survives a successful save; assert
`load_latest/0` on an empty directory returns `{:error, :not_found}`. A **shared contract
test** runs the identical assertions against both `SnapshotStore` and `FileSnapshotStore`, so
the two adapters are proven interchangeable rather than merely intended to be.
`notifier_test` uses a stub asserting the engine notifies on first critical deficit and does
not notify repeatedly while the deficit persists.

### 10.12 Desktop packaging

Cannot be unit tested. It is verified manually: `mix ex_tauri.dev`
launches the native window, the simulation ticks and the grid updates, closing the window
leaves a valid snapshot file that a subsequent launch hydrates from. That last check is the
one that actually exercises §8.3, so it is the one that matters most.

## 11. Deviations from the original specification

Each is a deliberate change, not an oversight:

1. Hydration in `handle_continue(:hydrate, …)` rather than `init/1`, so a slow database
   cannot block the supervision tree from booting.
2. `shutdown: 10_000` on the engine child spec, so `terminate/2` can finish its write.
3. Periodic checkpoint every 50 ticks in addition to `terminate/2`, because `terminate/2`
   does not run on a hard crash.
4. `delta_nodes` membership decided by `display_signature/1`, not raw struct equality.
5. Demolition uses a distinct `{:city_node_removed, id}` message; a removal cannot be
   expressed as a `stream_insert`.
6. `Repo` at `Infrastructure.Persistence.Repo` rather than `ArmchairMetropolist.Repo`.
7. Domain split into `Domain` (entities + ports) and `Domain.Services` (algorithms) so the
   web layer is compiler-barred from invoking simulation logic directly.
8. Baseline municipal capacity constant, so the first placed building does not starve.
9. `domain_purity_test` added, because `boundary` cannot enforce the "zero OTP" requirement.
10. `--warnings-as-errors` required, because boundary violations are warnings by default.
11. `SnapshotRepository.save/2` returns `:ok`, not `{:ok, id}` — the row id was a Postgres
    detail leaking through the port.
12. A second `Notifier` port, so the desktop shell dependency is swappable.
13. Desktop persistence is a file, not Postgres and not SQLite. Postgres cannot ship in a
    `.dmg`/`.appimage`; SQLite would add the `exqlite` NIF for no benefit, given the payload
    is a single opaque blob with no queries over it.
14. `Application.start/2` builds its child list from config, because the desktop target has no
    `Repo` to start.

## 12. Out of scope

No authentication, no multiplayer, no money/economy, no node upgrade levels, no undo, no
multiple save slots, no sound, no mobile-specific layout, no command write-ahead log.

**No cross-device sync, and therefore no Turso.** This was evaluated: `ecto_libsql` 0.9.1 is a
working Ecto adapter for libSQL with local-file, remote and embedded-replica modes, and it
would be the correct choice *if* cities needed to sync between machines. They do not. Without
a sync requirement it contributes a Rust NIF to a cross-compiled bundle and a dependency whose
maintainer has stated it is "likely to transition to maintenance mode" as Turso moves off
libSQL to its Rust rewrite — whose Elixir adapter, `turso_ex`, is early-stage and not yet
published to Hex. Storing one opaque blob is not a use case that justifies any of that.

Should sync become a goal, it re-enters as a `TursoSnapshotStore` behind the existing
`SnapshotRepository` port: one new module in `Infrastructure`, with `Domain`,
`Domain.Services` and `UseCases` untouched. Deferring costs nothing precisely because the port
exists.
