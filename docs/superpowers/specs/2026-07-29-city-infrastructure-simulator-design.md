# Armchair Metropolist — City Infrastructure Simulator

**Date:** 2026-07-29
**Status:** Design approved, pending spec review

## 1. Purpose

A real-time, event-driven city infrastructure simulator. A non-blocking OTP engine advances
a simulation tick every second, computing supply/demand and health decay across placed
infrastructure. A Phoenix LiveView dashboard renders the city and updates over WebSocket by
applying per-tick *diffs* rather than re-rendering the grid. State survives restarts via
compressed binary snapshots in Postgres.

The architecture is Clean/Hexagonal, and the layering is enforced at compile time by the
`boundary` library rather than by convention.

## 2. Verified environment

| Component | Version | Verified |
|---|---|---|
| Erlang/OTP | 29 (erts-17.0.4) | installed |
| Elixir | 1.20.2 | installed |
| Phoenix generator | `phx_new` 1.8.9 | installed |
| Postgres | 18.4, running on `:5432` | `pg_isready` OK |
| `boundary` | 0.10.4 (rel. 2024-09-25) | compat spiked on 1.20.2/OTP 29 — works |

## 3. Architecture

### 3.1 Layers

```
Domain            pure entities + ports. Zero OTP, zero Ecto, zero Phoenix.
Domain.Services   pure simulation algorithms. Reachable only from UseCases.
UseCases          orchestration. Depends on Domain + Domain.Services.
Infrastructure    OTP processes, Ecto adapters, PubSub. Implements the ports.
…Web              LiveView UI. Depends on UseCases + Domain entities.
```

Dependencies point inward only. `Domain` names the `SnapshotRepository` port;
`Infrastructure` implements it. That inversion is the point of the whole structure and it is
compiler-checked.

### 3.2 Boundary map

```elixir
# lib/armchair_metropolist/domain.ex
use Boundary, type: :strict, deps: [],
  exports: [Entities.CityMap, Entities.Node, Entities.SimulationMetrics,
            Ports.SnapshotRepository]

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
         Ecto, Ecto.Query, Ecto.Changeset, Ecto.Schema, Phoenix.PubSub],
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
         ArmchairMetropolistWeb]
```

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
*capacity* against waste *produced*; `traffic` models road capacity against trips generated.
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

### 4.5 Port

```elixir
defmodule ArmchairMetropolist.Domain.Ports.SnapshotRepository do
  @callback load_latest() ::
    {:ok, {tick :: non_neg_integer(), CityMap.t()}} | {:error, :not_found | term()}
  @callback save(tick :: non_neg_integer(), CityMap.t()) ::
    {:ok, id :: integer()} | {:error, term()}
end
```

The port speaks `CityMap` only. `:erlang.term_to_binary/2` and the MD5 checksum are
serialisation concerns and live entirely in the adapter — if `binary` or `checksum` appeared
in a callback signature, the domain would have learned about storage encoding and the
boundary would have leaked.

## 5. Use cases

- `AdvanceCityTick.execute(city_map)` → `{:ok, %{city_map:, delta:, metrics:}}`
- `ManageInfrastructure.place(city_map, x, y, type)` →
  `{:ok, {city_map, node}} | {:error, :out_of_bounds | :occupied | :unknown_type}`
- `ManageInfrastructure.demolish(city_map, x, y)` →
  `{:ok, {city_map, node_id}} | {:error, :empty}`

## 6. Infrastructure

### 6.1 Schema and migration

`priv/repo/migrations/20260729110000_create_city_snapshots.exs` creates `city_snapshots`:

| column | type | notes |
|---|---|---|
| `tick` | `integer` | not null |
| `payload` | `binary` | not null, compressed `term_to_binary` |
| `checksum` | `string` | not null, MD5 of payload, hex |
| `inserted_at`/`updated_at` | `utc_datetime_usec` | |

Index on `tick` descending, for the latest-snapshot lookup.

### 6.2 `SnapshotStore` (adapter)

Implements `SnapshotRepository`.

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

## 8. Tooling

`mix check` alias, and the same sequence in CI. The `test` alias is the one `phx.new`
generates (`ecto.create --quiet`, `ecto.migrate --quiet`, `test`), so the database is
prepared as part of the run:

```elixir
check: ["compile --force --warnings-as-errors", "test"]
```

`--force` matters: `boundary` only reports violations for modules it actually recompiles, so
an incremental compile can silently pass a violation that a clean compile would catch.

`boundary` ships `mix boundary.spec`, `mix boundary.visualize` and
`mix boundary.find_external_deps` for inspecting the enforced graph.

## 9. Testing strategy

Test-driven, using the `test-driven-development` skill. The purity constraint pays off here:
domain and use-case tests need neither a database nor a process.

**Domain (pure, no DB, no OTP)**
- `node_test` — production/consumption tables, status thresholds, `display_signature/1`.
- `city_map_test` — `new/2`, bounds, placement, occupancy, removal.
- `simulation_calculator_test` — satisfaction maths, decay and regen arithmetic, health
  clamping at 0 and 100, and a **cascading-failure** test asserting the death spiral when a
  power plant degrades.
- Delta tests: a fully-supplied stable city yields an **empty** delta; a starved city yields
  a delta containing only the starved nodes.
- `domain_purity_test` — the BEAM imports-table assertion of §3.3.

**Use cases** — against a hand-rolled in-memory stub implementing `SnapshotRepository`
(no Mox dependency). Placement validation, demolition, error tuples.

**Infrastructure** — `snapshot_store_test` against the real Postgres 18, including a
round-trip, latest-wins selection, and a **corrupted-checksum** case asserting
`{:error, :checksum_mismatch}`. `city_engine_test` covering hydration from a seeded snapshot,
fallback to an empty grid, delta broadcast on tick, and `terminate/2` persistence.
`tick_server_test` asserting the clock broadcasts and does not reference the engine.

**Web** — `simulator_live_test`: mount renders the grid, a broadcast delta updates only the
affected node, click places infrastructure.

## 10. Deviations from the original specification

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

## 11. Out of scope

No authentication, no multiplayer, no money/economy, no node upgrade levels, no undo, no
multiple save slots, no sound, no mobile-specific layout, no command write-ahead log.
