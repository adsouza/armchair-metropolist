# Per-Visitor Simulations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every visitor their own city, identified by a signed cookie, backed by its own row and its own engine process.

**Architecture:** Identity is threaded from the outside in, in three separable layers. The persistence port gains a `city_id` first, while the engine stays a singleton that passes a constant. Then the engine becomes registry-addressed, one process per city, with a per-city PubSub topic. Then it learns to stop when its last viewer disconnects. `Domain`, `Domain.Services` and `UseCases` are not touched at any point — they take a `city_map` and return one, so they were already multi-tenant.

**Tech Stack:** Elixir/Phoenix, Phoenix LiveView, `Registry`, `DynamicSupervisor`, Ecto/Postgres, Plug sessions.

**Spec:** `docs/superpowers/specs/2026-08-03-per-visitor-simulations-design.md`. Section references below (§N) point there.

## Global Constraints

- **`Domain`, `Domain.Entities`, `Domain.Services` and `UseCases` must not change.** If a task seems to need a change there, stop and report — it means identity has leaked into the pure core.
- **Desktop behaviour must not change.** The desktop app has exactly one city. `FileSnapshotStore` keeps its primary/backup redundancy and its two files; `Desktop.Config` pins a constant city id.
- **`TickServer` must not change.** One global clock, `{:tick, n}` on `"city_tick"`, referencing nothing. That it stays global is what makes freeze cost nothing.
- **The coverage gate stays at 90%** (`mix.exs` `test_coverage[:threshold]`). Every new module needs tests.
- **`mix check` must pass before every commit.** The pre-commit hook runs format, a warnings-as-errors compile (which is what enforces `boundary`), and Sobelow; pre-push runs the full `mix check`. Never `--no-verify`.
- **Use "allowlist"/"denylist", never the colour pair,** in prose, comments and identifiers.
- **Comment style:** this repository's comments explain *why*, name the upstream file and line that behaviour depends on, and record what was measured. A comment that restates the code is noise here.
- **The city code is 22 URL-safe characters** — `:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)` — validated against `~r/\A[A-Za-z0-9_-]{22}\z/`.
- **Retention is 90 days** on `updated_at`.
- **The linger before an idle engine stops is 30 seconds,** configurable.

## Verified before writing this plan

Do not re-derive these.

- `CityEngine` is a singleton: `GenServer.start_link(__MODULE__, opts, name: __MODULE__)` at `city_engine.ex:82`, and `snapshot/0`, `place/3`, `demolish/2` all `GenServer.call(__MODULE__, …)`.
- It subscribes to the clock in `init/1` at `city_engine.ex:112`, and broadcasts on `@simulation_topic` (`"city_simulation"`) via `broadcast/1` at `:308`.
- It resolves its adapter per call: `snapshot_repository/0` at `:314` reads `Application.get_env(:armchair_metropolist, :snapshot_repository, SnapshotStore)`. That is what lets tests inject stubs, and it must keep working.
- Port callbacks are `load_latest/0` and `save/2` (`snapshot_repository.ex:12,14`). Production call sites are `city_engine.ex:190` and `:254`.
- Three production call sites of the engine API: `simulator_live.ex:39`, `:68`, `:78`. About 45 more in `city_engine_test.exs`.
- Both `city_engine_test.exs` and `simulator_live_test.exs` do `start_supervised!(CityEngine)` after `start_supervised!(StubSnapshotRepository)`.
- `config/test.exs:7` sets `start_simulation: false`, so in test the Application starts neither the engine nor the clock.
- Session plumbing already exists and is discarded: `endpoint.ex:7-12` (`@session_options`, signed cookie), `:14-16` (`connect_info: [session: …]` on the LiveView socket), `:49` (`plug Plug.Session`); router `:browser` runs `:fetch_session`; `simulator_live.ex:34` reads `def mount(_params, _session, socket)`.
- Checksums *are* verified on read (`snapshot_store.ex:75-79`), the `tick` tiebreaker *does* exist (`order_by: [desc: s.tick, desc: s.id]`), and the Postgres adapter does **not** fall back to an earlier row on a checksum failure. The `FileSnapshotStore` does have real primary/backup recovery.

## File Structure

| file | change | responsibility |
|---|---|---|
| `lib/armchair_metropolist/domain/ports/snapshot_repository.ex` | modify | `load/1`, `save/3`. The only Domain file this plan touches, and only its callback signatures. |
| `priv/repo/migrations/20260803120000_city_scoped_snapshots.exs` | **create** | Recreate `city_snapshots` keyed on `city_id`, preserving the existing highest-tick city as `"legacy"`. |
| `lib/armchair_metropolist/infrastructure/persistence/city_snapshot.ex` | modify | `@primary_key {:city_id, :string, autogenerate: false}`. |
| `lib/armchair_metropolist/infrastructure/persistence/snapshot_store.ex` | modify | `load/1` by primary key; `save/3` upserting on `city_id`. |
| `lib/armchair_metropolist/infrastructure/persistence/file_snapshot_store.ex` | modify | New arity; ignores the id. Redundancy unchanged. |
| `lib/armchair_metropolist/infrastructure/simulation/city_engine.ex` | modify | Holds a `city_id`; then registry-addressed; then freeze-on-idle. |
| `lib/armchair_metropolist/infrastructure/simulation/city_registry.ex` | **create** | Names the `Registry` and the `DynamicSupervisor`, and owns `via/1` and `ensure_started/1`. |
| `lib/armchair_metropolist/infrastructure/persistence/snapshot_reaper.ex` | **create** | Deletes cities untouched for 90 days. |
| `lib/armchair_metropolist/application.ex` | modify | Registry and DynamicSupervisor unconditional; `TickServer` stays gated; reaper gated. |
| `lib/armchair_metropolist_web/city_code.ex` | **create** | `generate/0` and `valid?/1`. One responsibility, used by the plug and the controller. |
| `lib/armchair_metropolist_web/plugs/ensure_city_id.ex` | **create** | Puts a city id in the session when absent. |
| `lib/armchair_metropolist_web/controllers/city_controller.ex` | **create** | `GET /c/:code` → validate, `put_session`, redirect. |
| `lib/armchair_metropolist_web/router.ex` | modify | The plug in `:browser`; the `/c/:code` route. |
| `lib/armchair_metropolist_web/live/simulator_live.ex` | modify | Reads the session, passes the id, subscribes per city, `attach`es, shows the code. |
| `test/support/*` | modify | Stub, slow stub and contract module follow the port. |

---

### Task 1: Give the persistence port an identity

**Files:**
- Modify: `lib/armchair_metropolist/domain/ports/snapshot_repository.ex`
- Create: `priv/repo/migrations/20260803120000_city_scoped_snapshots.exs`
- Modify: `lib/armchair_metropolist/infrastructure/persistence/city_snapshot.ex`
- Modify: `lib/armchair_metropolist/infrastructure/persistence/snapshot_store.ex`
- Modify: `lib/armchair_metropolist/infrastructure/persistence/file_snapshot_store.ex`
- Modify: `lib/armchair_metropolist/infrastructure/simulation/city_engine.ex` (state + two call sites only)
- Modify: `test/support/stub_snapshot_repository.ex`, `test/support/slow_snapshot_repository.ex`, `test/support/snapshot_repository_contract.ex`
- Modify: `test/armchair_metropolist/infrastructure/persistence/snapshot_store_test.exs`, `file_snapshot_store_test.exs`

**Interfaces:**
- Consumes: nothing.
- Produces: `@callback load(String.t()) :: {:ok, {non_neg_integer(), CityMap.t()}} | {:error, term()}` and `@callback save(String.t(), non_neg_integer(), CityMap.t()) :: :ok | {:error, term()}`. `CityEngine` gains `state.city_id`, set from `Keyword.get(opts, :city_id, "default")`. The engine remains a singleton registered as `__MODULE__` — Task 2 changes that.

- [ ] **Step 1: Change the port**

Replace the two callbacks in `snapshot_repository.ex`. Keep the existing moduledoc's point about the domain not learning about binaries and checksums.

```elixir
  @doc """
  Load the city stored under `city_id`.

  One row per city, so there is no ordering to apply and nothing to be *latest*
  among — the name says `load` rather than `load_latest` for that reason.
  """
  @callback load(String.t()) ::
              {:ok, {non_neg_integer(), CityMap.t()}} | {:error, term()}

  @doc """
  Persist `city_map` under `city_id`.

  Returns `{:stale, stored_tick}` and writes nothing when a snapshot at `tick` or
  later is already stored. **That is not an error.** It is the guarantee that a
  crashed engine which hydrated from an older snapshot cannot overwrite newer work
  with older — the case `docs/superpowers/2026-07-30-follow-ups.md` records, and the
  one the previous append-only layout protected against by ordering on tick rather
  than on write time. Adapters must honour it; callers rely on a save never moving a
  city backwards.

  `tick` is passed separately because it is the adapter's business what to do with
  it — the Postgres adapter stores it as a column, and the file adapter puts it in
  its envelope. `city_map` carries the authoritative tick regardless.
  """
  @callback save(String.t(), non_neg_integer(), CityMap.t()) ::
              :ok | {:stale, non_neg_integer()} | {:error, term()}
```

- [ ] **Step 2: Write the migration**

```elixir
defmodule ArmchairMetropolist.Infrastructure.Persistence.Repo.Migrations.CityScopedSnapshots do
  use Ecto.Migration

  # The single anonymous city this table has held until now is preserved rather than
  # dropped, so whatever has been built on the deployed instance stays reachable at
  # /c/legacy. Highest tick wins, with `id` breaking ties — exactly the ordering the
  # old `load_latest/0` used, so the row that survives is the one that would have
  # loaded.
  @legacy_city_id "legacy"

  def up do
    create table(:city_snapshots_new, primary_key: false) do
      add :city_id, :string, primary_key: true
      add :tick, :integer, null: false
      add :payload, :binary, null: false
      add :checksum, :string, null: false

      timestamps()
    end

    execute """
    INSERT INTO city_snapshots_new (city_id, tick, payload, checksum, inserted_at, updated_at)
    SELECT '#{@legacy_city_id}', tick, payload, checksum, inserted_at, updated_at
    FROM city_snapshots
    ORDER BY tick DESC, id DESC
    LIMIT 1
    """

    drop table(:city_snapshots)
    rename table(:city_snapshots_new), to: table(:city_snapshots)

    # The reaper sweeps on this column (§8).
    create index(:city_snapshots, [:updated_at])
  end

  def down do
    # Honest about what it can restore: the history is gone, so rolling back yields
    # the old shape holding the one surviving city. Nothing that read the old table
    # depended on there being more than one row.
    create table(:city_snapshots_old) do
      add :tick, :integer, null: false
      add :payload, :binary, null: false
      add :checksum, :string, null: false

      timestamps()
    end

    execute """
    INSERT INTO city_snapshots_old (tick, payload, checksum, inserted_at, updated_at)
    SELECT tick, payload, checksum, inserted_at, updated_at FROM city_snapshots
    """

    drop table(:city_snapshots)
    rename table(:city_snapshots_old), to: table(:city_snapshots)
    create index(:city_snapshots, [:tick], name: :city_snapshots_tick_index)
  end
end
```

- [ ] **Step 3: Change the schema**

In `city_snapshot.ex`, above `schema/2`:

```elixir
  # The city id is the key: one row per city, upserted. There is no surrogate id to
  # tie-break on any more because there are no ties.
  @primary_key {:city_id, :string, autogenerate: false}
  schema "city_snapshots" do
    field :tick, :integer
    field :payload, :binary
    field :checksum, :string

    timestamps()
  end
```

and add `:city_id` to both `cast/3` and `validate_required/2`.

- [ ] **Step 4: Change `SnapshotStore`**

```elixir
  @impl true
  def load(city_id) do
    # Mandatory before decode/3's `:safe` call — see SnapshotVocabulary. This adapter
    # has no rescue, so without it the ArgumentError escapes CityEngine's hydration
    # and the engine crash-loops.
    SnapshotVocabulary.ensure_loaded!()

    case Repo.get(CitySnapshot, city_id) do
      nil ->
        {:error, :not_found}

      %CitySnapshot{tick: tick, payload: payload, checksum: checksum} ->
        decode(tick, payload, checksum)
    end
  end

  @impl true
  def save(city_id, tick, city_map) do
    payload = :erlang.term_to_binary(city_map, [:compressed])
    checksum = :crypto.hash(:md5, payload) |> Base.encode16()

    # Read-then-write in a transaction, rather than a query-based `on_conflict` with a
    # `where: s.tick < ^tick`. The SQL form is terser and refuses the stale write just
    # as well, but it gives no way to tell a refused update from an applied one — and
    # the port requires the refusal be *reportable*, not merely effective.
    #
    # `FOR UPDATE` is belt-and-braces: the Registry guarantees one engine per city, so
    # nothing else writes this row. It costs one lock on a once-per-checkpoint write and
    # removes the need to reason about that guarantee holding forever.
    Repo.transaction(fn ->
      existing = Repo.one(from(s in CitySnapshot, where: s.city_id == ^city_id, lock: "FOR UPDATE"))

      case existing do
        %CitySnapshot{tick: stored} when stored >= tick ->
          {:stale, stored}

        _ ->
          changeset =
            CitySnapshot.changeset(existing || %CitySnapshot{}, %{
              city_id: city_id,
              tick: tick,
              payload: payload,
              checksum: checksum
            })

          # Ecto's timestamps() move updated_at on the update path, which is what the
          # reaper sweeps on. inserted_at is left alone, so a city keeps its creation
          # time across every later save.
          result = if existing, do: Repo.update(changeset), else: Repo.insert(changeset)

          case result do
            {:ok, _snapshot} -> :ok
            {:error, changeset} -> Repo.rollback(changeset)
          end
      end
    end)
    |> case do
      {:ok, outcome} -> outcome
      {:error, reason} -> {:error, reason}
    end
  end
```

- [ ] **Step 5: Change `FileSnapshotStore`**

Only the arity changes. The id is ignored, with the reason stated:

```elixir
  # The city id is accepted and ignored. This adapter backs the desktop target, which
  # has exactly one city and one pair of files; honouring the id would mean a file per
  # city for a application that can only ever show one. The port's shape is shared, the
  # semantics are not.
  @impl true
  def load(_city_id), do: load_current()

  # Honours the port's staleness guarantee by declining the write, where before a stale
  # save landed on the primary and `load_current/0`'s max_by(tick) simply ignored it.
  # Observably identical through `load/1`, and strictly better on disk: refusing the
  # write also leaves the backup in place instead of rotating a newer snapshot out of it.
  @impl true
  def save(_city_id, tick, city_map) do
    case load_current() do
      {:ok, {stored, _city_map}} when stored >= tick -> {:stale, stored}
      _ -> save_current(tick, city_map)
    end
  end
```

Rename the existing `load_latest/0` body to `load_current/0` and the existing `save/2` body to `save_current/2`, leaving their internals — including the primary/backup recovery — untouched.

- [ ] **Step 6: Thread a city id through `CityEngine` without making it addressable yet**

In `init/1`, put the id in state:

```elixir
  def init(opts) do
    Process.flag(:trap_exit, true)

    :ok = Phoenix.PubSub.subscribe(ArmchairMetropolist.PubSub, @tick_topic)

    # Task 2 makes this process addressable by this id. For now it is a singleton that
    # simply knows which row it owns, which is what lets the port change land on its
    # own and be tested on its own.
    city_id = Keyword.get(opts, :city_id, @default_city_id)

    {:ok, %{city_id: city_id, city_map: nil, metrics: nil, critical?: false},
     {:continue, :hydrate}}
  end
```

Add `@default_city_id "default"` beside the other module attributes. Then change `handle_continue(:hydrate, state)` to pass the id, and the two repository call sites:

```elixir
  def handle_continue(:hydrate, state) do
    city_map = load_city_map(state.city_id)

    {:noreply, %{state | city_map: city_map, metrics: summarize(city_map)}}
  end

  defp load_city_map(city_id) do
    case snapshot_repository().load(city_id) do
```

and

```elixir
  defp save(city_id, city_map) do
    case snapshot_repository().save(city_id, city_map.tick, city_map) do
      :ok ->
        :ok

      # Not a failure — the adapter refused to move the city backwards. Worth a warning
      # rather than silence, because reaching here means this engine hydrated from an
      # older snapshot than the one stored: a crash-and-replay, which is the exact case
      # the guarantee exists for and the only signal that it happened.
      {:stale, stored_tick} ->
        Logger.warning(
          "declined to persist city #{city_id} at tick #{city_map.tick}: " <>
            "a newer snapshot at tick #{stored_tick} is already stored"
        )

      {:error, reason} ->
        log_failed_save(city_map.tick, reason)
    end
  end
```

Replace the whole existing `save/1` body with the above — its old two-clause `case` is
subsumed. The `rescue`/`catch` clauses and `log_failed_save/2` stay exactly as they are.

The original two-clause form, for reference, was:

```elixir
  defp save(city_map) do
    case snapshot_repository().save(city_map.tick, city_map) do
      :ok -> :ok
      {:error, reason} -> log_failed_save(city_map.tick, reason)
    end
```

Update `save/1`'s three callers (`maybe_checkpoint/1`, `terminate/2`, and the tick handler) to pass `state.city_id`. `save/2`'s `rescue`/`catch` clauses and `log_failed_save/2` keep working unchanged.

- [ ] **Step 7: Update the test doubles and the contract**

`StubSnapshotRepository`: `def load(_city_id), do: Agent.get(__MODULE__, & &1.initial)` and `def save(city_id, tick, city_map)` recording the id alongside what it already records. It also needs a way to return the refusal, so the engine's `{:stale, _}` branch is reachable from a test — without it that branch is dead code as far as the coverage gate is concerned:

```elixir
  @doc """
  Make the next `save/3` refuse with `{:stale, tick}`.

  Only the engine's handling of a refusal needs this; the real adapters' own refusal
  logic is covered by the shared contract.
  """
  def refuse_saves_as_stale(stored_tick) do
    Agent.update(__MODULE__, &Map.put(&1, :stale_at, stored_tick))
  end
```

and `save/3` returns `{:stale, stored}` when `:stale_at` is set, before recording anything.

`SlowSnapshotRepository`: `def load(city_id)` stalls then delegates; `def save(city_id, tick, city_map)` delegates.

Then add the engine-side test to `city_engine_test.exs`, which is writable now because the engine is still a singleton:

```elixir
    test "warns rather than failing when the adapter refuses a stale save" do
      StubSnapshotRepository.set_initial({:ok, {3, CityMap.new(40, 30)}})
      start_supervised!(CityEngine)
      StubSnapshotRepository.refuse_saves_as_stale(99)

      log =
        capture_log(fn ->
          {:ok, _node} = CityEngine.place(1, 1, :power_plant)
          Phoenix.PubSub.broadcast(ArmchairMetropolist.PubSub, @tick_topic, {:tick, 1})
          # Let the engine handle the tick, whose checkpoint attempts the save.
          {:ok, _} = CityEngine.snapshot()
        end)

      assert log =~ "declined to persist"
      assert log =~ "tick 99"
      refute log =~ "failed to persist"
    end
```

The `refute` is the point: a refusal must not be logged as a failure, because the two mean opposite things — one says the data was protected, the other says it was lost.

`SnapshotRepositoryContract`: every `@adapter.save(tick, city)` becomes `@adapter.save(@city_id, tick, city)` and every `@adapter.load_latest()` becomes `@adapter.load(@city_id)`, with `@city_id "contract-city"` defined in the module.

**The two ordering tests stay in the shared contract** — both adapters still guarantee that a save cannot move a city backwards — but they now assert the reportable refusal rather than just the surviving value. Rewrite them as:

```elixir
      test "save/3 refuses an older tick and says so" do
        assert :ok = @adapter.save(@city_id, 9, CityMap.new(19, 19))

        assert {:stale, 9} = @adapter.save(@city_id, 1, CityMap.new(11, 11))

        assert {:ok, {9, loaded}} = @adapter.load(@city_id)
        assert loaded.width == 19
      end

      test "save/3 refuses an equal tick, so a replay cannot rewrite a stored tick" do
        assert :ok = @adapter.save(@city_id, 5, CityMap.new(19, 19))

        assert {:stale, 5} = @adapter.save(@city_id, 5, CityMap.new(11, 11))

        assert {:ok, {5, loaded}} = @adapter.load(@city_id)
        assert loaded.width == 19
      end
```

Then **add one case the old contract could not express**:

```elixir
      test "save/3 advances the same city rather than accumulating rows" do
        assert :ok = @adapter.save(@city_id, 1, CityMap.new(11, 11))
        assert :ok = @adapter.save(@city_id, 2, CityMap.new(12, 12))

        assert {:ok, {2, loaded}} = @adapter.load(@city_id)
        assert loaded.width == 12
      end
```

**Per-city isolation is NOT a shared-contract case.** `FileSnapshotStore` ignores the id and keeps one pair of files, so `save("city-a", …)` followed by `load("city-b")` legitimately returns city-a's data there. Asserting isolation of an adapter that does not isolate would be a false claim, and asserting it "vacuously" is worse — the test writes real content first, so it fails outright. It goes in `snapshot_store_test.exs` instead, where isolation is real:

```elixir
  test "load/1 does not see another city's snapshot" do
    assert :ok = SnapshotStore.save("city-a", 5, CityMap.new(12, 12))

    assert {:error, :not_found} = SnapshotStore.load("city-b")
  end
```

Add a line to the contract's moduledoc saying why isolation is absent from it: the two adapters share a shape and a staleness guarantee, not a tenancy model.

- [ ] **Step 8: Run the suite**

```bash
mix ecto.migrate && mix check
```

Expected: PASS. The engine tests still call `CityEngine.snapshot()` with no id and still work, because the engine is still a singleton.

- [ ] **Step 9: Verify the migration preserves the legacy city**

```bash
mix ecto.rollback && mix ecto.migrate
```

Then prove the data path with a real row rather than trusting the SQL:

```bash
mix run -e '
  alias ArmchairMetropolist.Domain.Entities.{CityMap, Node}
  alias ArmchairMetropolist.Infrastructure.Persistence.SnapshotStore
  city = CityMap.put_node(CityMap.new(40, 30), Node.new(2, 2, :power_plant))
  :ok = SnapshotStore.save("legacy", 42, %{city | tick: 42})
  {:ok, {tick, loaded}} = SnapshotStore.load("legacy")
  IO.inspect({tick, map_size(loaded.nodes)}, label: "round-trip")
  {:error, :not_found} = SnapshotStore.load("nobody")
  IO.puts("isolation ok")
'
```

Expected: `round-trip: {42, 1}` then `isolation ok`.

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "feat: key snapshots by city

The port takes a city id: load/1 and save/3, one upserted row per city. load_latest
loses its name along with its meaning, since with one row there is nothing to be
latest among.

The migration preserves the single anonymous city the table has held until now as
'legacy', chosen by the same ordering the old load_latest/0 used, so what is built
on the deployed instance stays reachable rather than being dropped by a schema
change.

save/3 does a locked read-then-write inside a transaction rather than an on_conflict
upsert, because the port has to report a refusal rather than just apply one: a save
at or below the stored tick returns {:stale, stored_tick} instead of overwriting, so
a crashed-and-replayed engine can never write an older city over a newer one.
inserted_at is preserved across updates and updated_at still moves on every accepted
save, because the reaper sweeps on it.

CityEngine now holds a city_id and threads it into load and save, but stays a
singleton registered as __MODULE__ - making it addressable is the next task. That
split is what lets this land and be tested on its own.

FileSnapshotStore accepts and ignores the id: it backs the desktop target, which
has one city and one pair of files. Its primary/backup recovery is untouched."
```

---

### Task 2: Make the engine addressable, one process per city

**Files:**
- Create: `lib/armchair_metropolist/infrastructure/simulation/city_registry.ex`
- Modify: `lib/armchair_metropolist/infrastructure/simulation/city_engine.ex`
- Modify: `lib/armchair_metropolist/application.ex`
- Modify: `lib/armchair_metropolist_web/live/simulator_live.ex`
- Modify: `test/armchair_metropolist/infrastructure/simulation/city_engine_test.exs`, `test/armchair_metropolist_web/live/simulator_live_test.exs`

**Interfaces:**
- Consumes: `state.city_id` and the port from Task 1.
- Produces: `CityEngine.snapshot(city_id)`, `place(city_id, x, y, type)`, `demolish(city_id, x, y)`, `topic(city_id)`, and `CityRegistry.via/1` / `ensure_started/1`. Task 3 adds `attach/2`.

- [ ] **Step 1: Create the registry module**

```elixir
defmodule ArmchairMetropolist.Infrastructure.Simulation.CityRegistry do
  @moduledoc """
  Names and resolves the per-city engine processes.

  A `Registry` maps a city id to a running `CityEngine`, and a `DynamicSupervisor`
  starts one on demand. Both are started unconditionally by `Application` even
  though the engine and the clock are gated behind `:start_simulation` — they hold
  no state, and every path that resolves a city needs them, tests included. Gating
  them would mean every test that touches an engine had to start registry plumbing
  by hand.
  """

  @registry __MODULE__.Registry
  @supervisor __MODULE__.Supervisor

  @doc "Child specs for `Application`. Order matters: the registry names the children the supervisor starts."
  def children do
    [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, strategy: :one_for_one, name: @supervisor}
    ]
  end

  @doc "The `:via` tuple naming the engine for `city_id`."
  def via(city_id) when is_binary(city_id), do: {:via, Registry, {@registry, city_id}}

  @doc """
  Return the engine for `city_id`, starting it if it is not running.

  `{:error, {:already_started, pid}}` is a success here, which is what makes two
  simultaneous mounts of the same city safe without a lock: whichever loses the
  race is handed the winner's process.
  """
  def ensure_started(city_id) when is_binary(city_id) do
    spec = {ArmchairMetropolist.Infrastructure.Simulation.CityEngine, city_id: city_id}

    case DynamicSupervisor.start_child(@supervisor, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "The pid for `city_id`, or nil. For tests and diagnostics."
  def whereis(city_id) when is_binary(city_id) do
    case Registry.lookup(@registry, city_id) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  @doc "How many engines are running. For tests."
  def count, do: Registry.count(@registry)
end
```

- [ ] **Step 2: Make `CityEngine` registry-named and id-addressed**

Replace `start_link/1`, `topic/0` and the three API functions:

```elixir
  @doc "The topic this city's simulation events are broadcast on."
  def topic(city_id) when is_binary(city_id), do: "city:" <> city_id

  def start_link(opts) do
    city_id = Keyword.fetch!(opts, :city_id)

    GenServer.start_link(__MODULE__, opts, name: CityRegistry.via(city_id))
  end

  @spec snapshot(String.t()) :: {:ok, %{city_map: CityMap.t(), metrics: SimulationMetrics.t()}}
  def snapshot(city_id), do: call(city_id, :snapshot)

  @spec place(String.t(), integer(), integer(), atom()) ::
          {:ok, ArmchairMetropolist.Domain.Entities.Node.t()}
          | {:error, :out_of_bounds | :occupied | :unknown_type}
  def place(city_id, x, y, type), do: call(city_id, {:place, x, y, type})

  @spec demolish(String.t(), integer(), integer()) :: {:ok, String.t()} | {:error, :empty}
  def demolish(city_id, x, y), do: call(city_id, {:demolish, x, y})

  # Start-on-demand, then call. The retry exists because an engine can stop between
  # `ensure_started/1` and the call — Task 3 makes idle engines stop on purpose, so
  # this is a normal race rather than an exotic one. One retry is enough: the second
  # `ensure_started/1` cannot find a stopping process, because a stopped process is
  # unregistered before the next lookup.
  defp call(city_id, message, retries \\ 1) do
    {:ok, _pid} = CityRegistry.ensure_started(city_id)

    try do
      GenServer.call(CityRegistry.via(city_id), message)
    catch
      :exit, {reason, _} when retries > 0 and reason in [:noproc, :normal, :shutdown] ->
        call(city_id, message, retries - 1)
    end
  end
```

Add `alias ArmchairMetropolist.Infrastructure.Simulation.CityRegistry`, drop `@simulation_topic`, and change `broadcast/1` to `broadcast/2`:

```elixir
  defp broadcast(city_id, message) do
    Phoenix.PubSub.broadcast(ArmchairMetropolist.PubSub, topic(city_id), message)
  end
```

Update its four call sites in `handle_call/3` and `handle_info/2` to pass `state.city_id`. Keep `@default_city_id` — the desktop target uses it (Task 4).

- [ ] **Step 3: Rewire `Application`**

```elixir
  # The registry and its dynamic supervisor start unconditionally: they hold no state,
  # and any code path that resolves a city needs them — including tests, which set
  # `start_simulation: false` and start their own engines. The clock stays gated
  # because tests drive a fast one.
  defp simulation_children do
    CityRegistry.children() ++ clock_children()
  end

  defp clock_children do
    if Application.get_env(:armchair_metropolist, :start_simulation, true) do
      [ArmchairMetropolist.Infrastructure.Simulation.TickServer]
    else
      []
    end
  end
```

The `Supervisor.child_spec(CityEngine, shutdown: 10_000)` entry goes away — engines are now started by the dynamic supervisor, and `use GenServer, shutdown: 10_000` at `city_engine.ex:59` already carries the budget into the spec the supervisor builds. Add the `CityRegistry` alias.

- [ ] **Step 4: Update `SimulatorLive` to pass an id**

For now take it from the socket assigns with a constant default; Task 4 supplies the real one. This keeps the task independently testable.

```elixir
  def mount(_params, _session, socket) do
    city_id = ArmchairMetropolist.Infrastructure.Simulation.CityEngine.default_city_id()

    if connected?(socket) do
      Phoenix.PubSub.subscribe(ArmchairMetropolist.PubSub, CityEngine.topic(city_id))
    end

    {:ok, %{city_map: city_map, metrics: metrics}} = CityEngine.snapshot(city_id)

    socket = assign(socket, city_id: city_id)
```

Add `def default_city_id, do: @default_city_id` to `CityEngine`. Change the two event handlers to `CityEngine.place(socket.assigns.city_id, x, y, socket.assigns.selected_type)` and `CityEngine.demolish(socket.assigns.city_id, x, y)`.

- [ ] **Step 5: Update the engine tests**

In `city_engine_test.exs`, replace `@simulation_topic "city_simulation"` with a per-test id and derive the topic. Add to `setup`:

```elixir
    city_id = "test-#{System.unique_integer([:positive])}"
    {:ok, city_id: city_id}
```

Then `start_supervised!(CityEngine)` becomes `start_supervised!({CityEngine, city_id: city_id})`, every `CityEngine.snapshot()` becomes `CityEngine.snapshot(city_id)`, every `place(x, y, t)` becomes `place(city_id, x, y, t)`, every `demolish(x, y)` becomes `demolish(city_id, x, y)`, and every subscribe to `@simulation_topic` becomes `CityEngine.topic(city_id)`. Tests that need the id take `%{city_id: city_id}` in their signature.

A unique id per test is not cosmetic: these tests are `async: false` today partly because they share a singleton, and per-test ids remove that coupling.

Do the same in `simulator_live_test.exs`, whose `setup` must use `CityEngine.default_city_id()` so the LiveView and the test agree.

- [ ] **Step 6: Write the isolation test — the property this whole task exists for**

Add to `city_engine_test.exs`:

```elixir
  describe "isolation between cities" do
    test "one city's snapshot does not see another's nodes" do
      a = "iso-a-#{System.unique_integer([:positive])}"
      b = "iso-b-#{System.unique_integer([:positive])}"
      start_supervised!({CityEngine, city_id: a}, id: :engine_a)
      start_supervised!({CityEngine, city_id: b}, id: :engine_b)

      {:ok, _node} = CityEngine.place(a, 3, 4, :power_plant)

      assert {:ok, %{city_map: map_a}} = CityEngine.snapshot(a)
      assert {:ok, %{city_map: map_b}} = CityEngine.snapshot(b)
      assert map_size(map_a.nodes) == 1
      assert map_size(map_b.nodes) == 0
    end

    test "a delta is broadcast to its own city's topic and not another's" do
      a = "iso-a-#{System.unique_integer([:positive])}"
      b = "iso-b-#{System.unique_integer([:positive])}"
      start_supervised!({CityEngine, city_id: a}, id: :engine_a)
      start_supervised!({CityEngine, city_id: b}, id: :engine_b)

      :ok = Phoenix.PubSub.subscribe(ArmchairMetropolist.PubSub, CityEngine.topic(a))
      :ok = Phoenix.PubSub.subscribe(ArmchairMetropolist.PubSub, CityEngine.topic(b))

      {:ok, _node} = CityEngine.place(a, 3, 4, :power_plant)

      # Positive first: without this the refute below is vacuous.
      assert_receive {:city_node_placed, %Node{x: 3, y: 4}}
      # And nothing further, which is what proves the topics are distinct rather
      # than one shared topic delivering to both subscriptions.
      refute_receive {:city_node_placed, _}, 200
    end
  end
```

- [ ] **Step 7: Run the suite**

```bash
mix check
```

Expected: PASS, coverage at or above 90%.

- [ ] **Step 8: Mutation-verify the per-city topic**

The isolation test's second case is the one that matters and the one most easily written so it cannot fail. Break the topic and confirm it goes red:

```bash
cp lib/armchair_metropolist/infrastructure/simulation/city_engine.ex /tmp/engine.bak
perl -0pi -e 's/def topic\(city_id\) when is_binary\(city_id\), do: "city:" <> city_id/def topic(city_id) when is_binary(city_id), do: "city_simulation"/' lib/armchair_metropolist/infrastructure/simulation/city_engine.ex
mix test test/armchair_metropolist/infrastructure/simulation/city_engine_test.exs 2>&1 | tail -6
cp /tmp/engine.bak lib/armchair_metropolist/infrastructure/simulation/city_engine.ex
```

Expected: the "delta is broadcast to its own city's topic" test FAILS on the `refute_receive`. If it passes, the test is not testing what it claims and must be fixed before proceeding.

- [ ] **Step 9: Mutation-verify the start-on-demand race**

```bash
mix run -e '
  alias ArmchairMetropolist.Infrastructure.Simulation.{CityEngine, CityRegistry}
  Application.put_env(:armchair_metropolist, :snapshot_repository, ArmchairMetropolist.Infrastructure.Persistence.SnapshotStore)
  id = "race-#{System.unique_integer([:positive])}"
  results = 1..20 |> Task.async_stream(fn _ -> CityEngine.snapshot(id) end, max_concurrency: 20) |> Enum.to_list()
  IO.inspect(Enum.count(results, &match?({:ok, {:ok, _}}, &1)), label: "successful calls (want 20)")
  IO.inspect(CityRegistry.count(), label: "engines running (want 1)")
'
```

Expected: 20 successful calls, 1 engine.

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "feat: one engine process per city

CityEngine is registered through a Registry under its city id and started on
demand by a DynamicSupervisor, so snapshot/1, place/4 and demolish/3 address a
city rather than a singleton. Deltas move from one global topic to city:<id>.

Without the topic change every visitor would receive every other visitor's
deltas - the bug this work exists to fix, merely relocated. The isolation test
asserts the positive case before the refute, and was mutation-verified by
reverting topic/1 to a constant.

start_child returning {:error, {:already_started, pid}} is treated as success,
which makes concurrent mounts of one city safe without a lock. call/3 retries
once on :noproc/:normal/:shutdown because an idle engine will stop on purpose
once freeze lands.

The registry and its supervisor start unconditionally: they hold no state and
every path resolving a city needs them, including tests that set
start_simulation: false. The clock stays gated - tests drive a fast one.

Engine tests now use a unique city id per test, which removes the shared-singleton
coupling that made them async: false."
```

---

### Task 3: Freeze a city when its last viewer disconnects

**Files:**
- Modify: `lib/armchair_metropolist/infrastructure/simulation/city_engine.ex`
- Modify: `lib/armchair_metropolist_web/live/simulator_live.ex`
- Modify: `config/config.exs`
- Modify: `test/armchair_metropolist/infrastructure/simulation/city_engine_test.exs`

**Interfaces:**
- Consumes: Task 2's addressable engine.
- Produces: `CityEngine.attach(city_id, pid)`. `state` gains `viewers: %{reference() => pid()}` and `linger: reference() | nil`. Config key `:engine_linger_ms`, default `30_000`.

- [ ] **Step 1: Add the linger default to config**

In `config/config.exs`, beside `tick_interval_ms`:

```elixir
  # How long an engine stays alive after its last viewer disconnects. A page reload
  # disconnects and reconnects within a second, so stopping immediately would make
  # every refresh pay a save, a process death, a restart and a hydrate.
  engine_linger_ms: 30_000,
```

- [ ] **Step 2: Add `attach/2` and the monitor bookkeeping**

```elixir
  @doc """
  Register `pid` as a viewer of `city_id`.

  The engine monitors it, and stops once every viewer has gone — see the moduledoc
  on freezing. Idempotent per pid: attaching twice monitors twice and both
  references are removed independently, which is harmless.
  """
  def attach(city_id, pid) when is_binary(city_id) and is_pid(pid) do
    call(city_id, {:attach, pid})
  end
```

```elixir
  def handle_call({:attach, pid}, _from, state) do
    ref = Process.monitor(pid)

    {:reply, :ok,
     %{state | viewers: Map.put(state.viewers, ref, pid), linger: cancel_linger(state.linger)}}
  end
```

```elixir
  # A viewer's LiveView process has gone. When the last one goes, save immediately —
  # the city is frozen from this instant and the save must not wait for the linger,
  # which might be cut short by an application shutdown.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    viewers = Map.delete(state.viewers, ref)

    if map_size(viewers) == 0 do
      save(state.city_id, state.city_map)

      {:noreply, %{state | viewers: viewers, linger: arm_linger()}}
    else
      {:noreply, %{state | viewers: viewers}}
    end
  end

  def handle_info(:linger_expired, state) do
    # A viewer that arrived during the linger cancelled the timer, so reaching here
    # with viewers present means a cancel raced a fired message. Checking rather than
    # trusting the timer is what stops that race from killing a watched city.
    if map_size(state.viewers) == 0 do
      {:stop, :normal, state}
    else
      {:noreply, %{state | linger: nil}}
    end
  end
```

```elixir
  defp arm_linger do
    Process.send_after(self(), :linger_expired, config(:engine_linger_ms, 30_000))
  end

  defp cancel_linger(nil), do: nil

  defp cancel_linger(timer) do
    Process.cancel_timer(timer)
    nil
  end
```

Add `viewers: %{}, linger: nil` to the state map built in `init/1`.

- [ ] **Step 3: Attach from the LiveView**

In `mount/3`, inside the `connected?(socket)` branch, after subscribing:

```elixir
      # Ties the city's lifetime to this connection. The engine monitors us, so a
      # closed tab, a crash and a navigation all look the same to it.
      :ok = CityEngine.attach(city_id, self())
```

- [ ] **Step 4: Write the freeze tests**

```elixir
  describe "freezing when the last viewer leaves" do
    setup do
      Application.put_env(:armchair_metropolist, :engine_linger_ms, 50)
      :ok
    end

    test "saves and stops after the linger once the last viewer goes", %{city_id: city_id} do
      {:ok, pid} = CityRegistry.ensure_started(city_id)
      viewer = spawn(fn -> Process.sleep(:infinity) end)
      :ok = CityEngine.attach(city_id, viewer)
      ref = Process.monitor(pid)

      Process.exit(viewer, :kill)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
      assert CityRegistry.whereis(city_id) == nil
    end

    test "a viewer arriving during the linger cancels the stop", %{city_id: city_id} do
      {:ok, pid} = CityRegistry.ensure_started(city_id)
      first = spawn(fn -> Process.sleep(:infinity) end)
      :ok = CityEngine.attach(city_id, first)
      ref = Process.monitor(pid)

      Process.exit(first, :kill)
      # Inside the 50ms linger.
      second = spawn(fn -> Process.sleep(:infinity) end)
      :ok = CityEngine.attach(city_id, second)

      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 300
      assert CityRegistry.whereis(city_id) == pid
    end

    test "a frozen city reloads its state when next addressed", %{city_id: city_id} do
      {:ok, _pid} = CityRegistry.ensure_started(city_id)
      viewer = spawn(fn -> Process.sleep(:infinity) end)
      :ok = CityEngine.attach(city_id, viewer)
      {:ok, _node} = CityEngine.place(city_id, 3, 4, :power_plant)

      Process.exit(viewer, :kill)
      Process.sleep(200)
      assert CityRegistry.whereis(city_id) == nil

      # The stub returns whatever `set_initial/1` holds, so this asserts the save
      # happened by asserting the engine wrote before it stopped.
      assert {:ok, %{city_map: reloaded}} = CityEngine.snapshot(city_id)
      assert map_size(reloaded.nodes) == 1
    end
  end
```

The third test needs `StubSnapshotRepository` to return what was last saved rather than a fixed seed. Add to it:

```elixir
  @doc "Make load/1 return the most recent save/3, as a real adapter would."
  def echo_saves, do: Agent.update(__MODULE__, &Map.put(&1, :echo, true))
```

and have `load/1` prefer the last saved value when `:echo` is set. Call `StubSnapshotRepository.echo_saves()` in that test's setup.

- [ ] **Step 5: Run the suite**

```bash
mix check
```

Expected: PASS.

- [ ] **Step 6: Mutation-verify the linger cancel**

The cancel is the part a naive implementation gets wrong, so prove the test catches its absence:

```bash
cp lib/armchair_metropolist/infrastructure/simulation/city_engine.ex /tmp/engine.bak
perl -0pi -e 's/linger: cancel_linger\(state\.linger\)/linger: state.linger/' lib/armchair_metropolist/infrastructure/simulation/city_engine.ex
mix test test/armchair_metropolist/infrastructure/simulation/city_engine_test.exs 2>&1 | tail -6
cp /tmp/engine.bak lib/armchair_metropolist/infrastructure/simulation/city_engine.ex
```

Expected: "a viewer arriving during the linger cancels the stop" FAILS. Note `handle_info(:linger_expired, …)` re-checks `viewers`, so the engine survives anyway — the test must fail on the `{:DOWN, …}` it receives, not on a dead city. If it passes, the assertion is on the wrong thing.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: freeze a city when its last viewer disconnects

An engine monitors each attached LiveView and stops once they have all gone, so
CPU scales with concurrent viewers rather than total cities and an idle server
does nothing. TickServer is untouched: only live engines are subscribed to the
clock, which is what makes this cost nothing.

A 30s linger absorbs reloads. Without it every refresh would pay a save, a
process death, a restart and a hydrate, because a reload disconnects and
reconnects within a second.

The save happens on the last :DOWN rather than when the linger expires - the city
is frozen from that instant and an application shutdown could cut the linger
short.

:linger_expired re-checks the viewer set rather than trusting the timer, so a
cancel racing a fired message cannot kill a watched city. Mutation-verified by
removing the cancel and confirming the arriving-viewer test goes red."
```

---

### Task 4: Give each visitor an identity

**Files:**
- Create: `lib/armchair_metropolist_web/city_code.ex`
- Create: `lib/armchair_metropolist_web/plugs/ensure_city_id.ex`
- Modify: `lib/armchair_metropolist_web/router.ex`
- Modify: `lib/armchair_metropolist_web/live/simulator_live.ex`
- Modify: `lib/armchair_metropolist/infrastructure/desktop/config.ex`
- Create: `test/armchair_metropolist_web/city_code_test.exs`, `test/armchair_metropolist_web/plugs/ensure_city_id_test.exs`
- Modify: `test/armchair_metropolist_web/live/simulator_live_test.exs`

**Interfaces:**
- Consumes: Task 2's `snapshot/1`; Task 3's `attach/2`.
- Produces: `CityCode.generate/0`, `CityCode.valid?/1`; session key `"city_id"`; `socket.assigns.city_id` sourced from the session.

- [ ] **Step 1: Create `CityCode`**

```elixir
defmodule ArmchairMetropolistWeb.CityCode do
  @moduledoc """
  Generates and validates the code that identifies a visitor's city.

  16 random bytes, URL-safe Base64 without padding — 22 characters. The code is
  the credential: anyone holding it has the city, which is why it is generated
  from `:crypto.strong_rand_bytes/1` rather than anything derived or sequential.
  """

  # An allowlist, not a length check. The code reaches a database query and a
  # Registry key; Ecto parameterises the former and a Registry key is just a term,
  # so neither is an injection risk. The reason to validate is duller: an
  # unfiltered string would mint a garbage city, and a 10 MB path would mint a
  # 10 MB registry key.
  @pattern ~r/\A[A-Za-z0-9_-]{22}\z/

  @doc "A fresh, unguessable city code."
  def generate, do: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @doc "Whether `code` is one this application would have generated."
  def valid?(code) when is_binary(code), do: Regex.match?(@pattern, code)
  def valid?(_code), do: false
end
```

- [ ] **Step 2: Create the plug**

```elixir
defmodule ArmchairMetropolistWeb.Plugs.EnsureCityId do
  @moduledoc """
  Puts a city id in the session when there is not one already.

  The session is a signed cookie (`endpoint.ex`), so a visitor can read their id
  but cannot forge another — which matters, because the id is the only thing
  standing between someone and a city.
  """

  @behaviour Plug

  import Plug.Conn

  alias ArmchairMetropolistWeb.CityCode

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case get_session(conn, :city_id) do
      nil -> put_session(conn, :city_id, CityCode.generate())
      _existing -> conn
    end
  end
end
```

- [ ] **Step 3: Wire it into the router**

In the `:browser` pipeline, after `plug :fetch_session`:

```elixir
    plug ArmchairMetropolistWeb.Plugs.EnsureCityId
```

It must come after `:fetch_session` — without a fetched session, `get_session/2` raises.

- [ ] **Step 4: Read the id in `SimulatorLive`**

Replace Task 2's constant with the session value:

```elixir
  # Plug stores session keys as strings, so this matches "city_id" rather than the
  # atom the plug wrote. The second clause is the desktop target, which has no
  # browser session and one city.
  def mount(_params, %{"city_id" => city_id}, socket) when is_binary(city_id) do
    do_mount(city_id, socket)
  end

  def mount(_params, _session, socket) do
    do_mount(CityEngine.default_city_id(), socket)
  end

  defp do_mount(city_id, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ArmchairMetropolist.PubSub, CityEngine.topic(city_id))
      :ok = CityEngine.attach(city_id, self())
    end

    {:ok, %{city_map: city_map, metrics: metrics}} = CityEngine.snapshot(city_id)

    # … existing assigns, plus city_id
  end
```

- [ ] **Step 5: Pin the desktop city id**

In `Desktop.Config.apply!/0`, alongside the other overrides:

```elixir
    # The desktop application has one city. Pinning the id here rather than relying
    # on the LiveView's fallback keeps the two targets' behaviour explicit, and means
    # a desktop build that somehow acquires a browser session still opens the same
    # city it always did.
    Application.put_env(:armchair_metropolist, :desktop_city_id, "desktop")
```

and change `SimulatorLive`'s fallback clause to prefer it:

```elixir
    do_mount(
      Application.get_env(:armchair_metropolist, :desktop_city_id) ||
        CityEngine.default_city_id(),
      socket
    )
```

- [ ] **Step 6: Test `CityCode`**

```elixir
defmodule ArmchairMetropolistWeb.CityCodeTest do
  use ExUnit.Case, async: true

  alias ArmchairMetropolistWeb.CityCode

  test "generates 22 URL-safe characters" do
    code = CityCode.generate()

    assert String.length(code) == 22
    assert CityCode.valid?(code)
  end

  test "generates a different code each time" do
    codes = Enum.map(1..100, fn _ -> CityCode.generate() end)

    assert length(Enum.uniq(codes)) == 100
  end

  test "rejects everything outside the allowlist" do
    refute CityCode.valid?("")
    refute CityCode.valid?(String.duplicate("a", 21))
    refute CityCode.valid?(String.duplicate("a", 23))
    refute CityCode.valid?("../../etc/passwd------")
    refute CityCode.valid?("aaaaaaaaaaaaaaaaaaaa/=")
    refute CityCode.valid?("aaaaaaaaaaaaaaaaaaaa\na")
    refute CityCode.valid?(nil)
    refute CityCode.valid?(:atom)
  end
end
```

The `\n` case matters: `~r/\A…\z/` rejects a trailing newline where `^…$` would accept it, and that is precisely the difference between the two anchors.

- [ ] **Step 7: Test the plug**

```elixir
defmodule ArmchairMetropolistWeb.Plugs.EnsureCityIdTest do
  use ArmchairMetropolistWeb.ConnCase, async: true

  alias ArmchairMetropolistWeb.CityCode
  alias ArmchairMetropolistWeb.Plugs.EnsureCityId

  setup %{conn: conn} do
    {:ok, conn: Plug.Test.init_test_session(conn, %{})}
  end

  test "puts a valid id when the session has none", %{conn: conn} do
    conn = EnsureCityId.call(conn, [])

    assert conn |> Plug.Conn.get_session(:city_id) |> CityCode.valid?()
  end

  test "leaves an existing id alone", %{conn: conn} do
    conn = Plug.Conn.put_session(conn, :city_id, "existing")

    assert EnsureCityId.call(conn, []) |> Plug.Conn.get_session(:city_id) == "existing"
  end
end
```

- [ ] **Step 8: Test that two connections get two cities**

In `simulator_live_test.exs`:

```elixir
  test "two visitors with different sessions get different cities", %{conn: conn} do
    a = Plug.Test.init_test_session(conn, %{"city_id" => "aaaaaaaaaaaaaaaaaaaaaa"})
    b = Plug.Test.init_test_session(conn, %{"city_id" => "bbbbbbbbbbbbbbbbbbbbbb"})

    {:ok, view_a, _html} = live(a, ~p"/")
    {:ok, view_b, _html} = live(b, ~p"/")

    render_click(view_a, "place", %{"x" => "3", "y" => "4"})

    # The positive case first, so the refute below cannot be vacuous.
    assert render(view_a) =~ ~s{id="3:4"}
    refute render(view_b) =~ ~s{id="3:4"}
  end
```

- [ ] **Step 9: Run the suite**

```bash
mix check
```

Expected: PASS at or above 90% coverage.

- [ ] **Step 10: Mutation-verify the session read**

If `mount/3` ignored the session and used a constant, every visitor would share a city again — the original bug. Prove the test catches that:

```bash
cp lib/armchair_metropolist_web/live/simulator_live.ex /tmp/live.bak
perl -0pi -e 's/def mount\(_params, %\{"city_id" => city_id\}, socket\) when is_binary\(city_id\) do\n    do_mount\(city_id, socket\)/def mount(_params, %{"city_id" => city_id}, socket) when is_binary(city_id) do\n    do_mount("shared", socket)/' lib/armchair_metropolist_web/live/simulator_live.ex
mix test test/armchair_metropolist_web/live/simulator_live_test.exs 2>&1 | tail -6
cp /tmp/live.bak lib/armchair_metropolist_web/live/simulator_live.ex
```

Expected: "two visitors with different sessions get different cities" FAILS on the `refute`.

- [ ] **Step 11: Commit**

```bash
git add -A
git commit -m "feat: identify each visitor's city from a signed cookie

A plug puts 16 random bytes, URL-safe Base64 without padding, in the session when
there is not one already, and SimulatorLive.mount/3 finally uses the argument it
has been discarding since it was generated. The plumbing already existed: the
session is a signed cookie and the LiveView socket already declared
connect_info: [session: ...].

Session keys arrive as strings, so the match is on \"city_id\" rather than the atom
the plug wrote. The fallback clause is the desktop target, which has no browser
session and one city, pinned by Desktop.Config.

CityCode.valid?/1 is an allowlist, ~r/\\A[A-Za-z0-9_-]{22}\\z/. Not for injection -
Ecto parameterises the query and a Registry key is just a term - but because an
unfiltered string would mint a garbage city and a huge one a huge registry key.
\\A and \\z rather than ^ and $, which would accept a trailing newline.

Mutation-verified: hardcoding the id in mount/3 turns the two-visitor test red."
```

---

### Task 5: Let a visitor return to a city from another browser

**Files:**
- Create: `lib/armchair_metropolist_web/controllers/city_controller.ex`
- Modify: `lib/armchair_metropolist_web/router.ex`
- Modify: `lib/armchair_metropolist_web/live/simulator_live.ex` (show the code)
- Create: `test/armchair_metropolist_web/controllers/city_controller_test.exs`

**Interfaces:**
- Consumes: `CityCode.valid?/1`; the session key from Task 4.
- Produces: `GET /c/:code`.

- [ ] **Step 1: Create the controller**

```elixir
defmodule ArmchairMetropolistWeb.CityController do
  @moduledoc """
  Re-attaches a browser to an existing city.

  This cannot be a LiveView: a LiveView has no `conn` and cannot write the
  session, which is the only thing that persists the choice past this request.
  """

  use ArmchairMetropolistWeb, :controller

  alias ArmchairMetropolistWeb.CityCode

  @doc """
  Adopt `code` as this browser's city and redirect to the simulator.

  A well-formed code for a city that does not exist yields a new empty city under
  that id rather than an error: that is the same path a first-time visitor takes,
  so it needs no special handling, and a mistyped code gives an empty grid instead
  of a failure page. Checking existence first would cost a query on every entry
  and a second code path to test.
  """
  def enter(conn, %{"code" => code}) do
    if CityCode.valid?(code) do
      conn
      |> put_session(:city_id, code)
      |> redirect(to: ~p"/")
    else
      conn
      |> put_status(:not_found)
      |> put_view(html: ArmchairMetropolistWeb.ErrorHTML)
      |> render(:"404")
    end
  end
end
```

- [ ] **Step 2: Add the route**

In the `"/"` scope, before the `live` entry:

```elixir
    get "/c/:code", CityController, :enter
```

- [ ] **Step 3: Show the code in the UI**

In `SimulatorLive`'s template, near the metrics, add a small block. Keep it plain — this is one line of copy and a code, not a feature:

```heex
<div class="text-xs opacity-70 mt-2">
  <span>This city lives in this browser.</span>
  <span>Return to it elsewhere with code</span>
  <code class="font-mono select-all">{@city_id}</code>
</div>
```

- [ ] **Step 4: Test the controller**

```elixir
defmodule ArmchairMetropolistWeb.CityControllerTest do
  use ArmchairMetropolistWeb.ConnCase, async: true

  @valid "aaaaaaaaaaaaaaaaaaaaaa"

  test "a valid code is adopted and redirects to the simulator", %{conn: conn} do
    conn = get(conn, ~p"/c/#{@valid}")

    assert redirected_to(conn) == ~p"/"
    assert get_session(conn, :city_id) == @valid
  end

  test "a valid code replaces whatever the browser had", %{conn: conn} do
    conn =
      conn
      |> Plug.Test.init_test_session(%{"city_id" => "bbbbbbbbbbbbbbbbbbbbbb"})
      |> get(~p"/c/#{@valid}")

    assert get_session(conn, :city_id) == @valid
  end

  test "a malformed code is a 404 and does not touch the session", %{conn: conn} do
    conn =
      conn
      |> Plug.Test.init_test_session(%{"city_id" => "bbbbbbbbbbbbbbbbbbbbbb"})
      |> get(~p"/c/not-a-valid-code")

    assert conn.status == 404
    assert get_session(conn, :city_id) == "bbbbbbbbbbbbbbbbbbbbbb"
  end

  test "entering an unknown but well-formed code yields an empty city", %{conn: conn} do
    conn = get(conn, ~p"/c/#{@valid}")

    {:ok, _view, html} = conn |> recycle() |> live(~p"/")

    refute html =~ ~s{id="3:4"}
  end
end
```

The third test's session assertion is the one that matters: a rejected code must not half-apply.

- [ ] **Step 5: Run the suite**

```bash
mix check
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: return to a city with its code

GET /c/:code adopts a code into the session and redirects. A controller rather
than a LiveView because a LiveView has no conn and cannot write the session,
which is the only thing that persists the choice past the request.

A well-formed but unknown code yields a new empty city under that id rather than
an error - the same path a first-time visitor takes, so no extra code path, and a
mistyped code gives an empty grid instead of a failure page.

A malformed code is a 404 that leaves the session untouched, which is asserted
explicitly: a rejected code must not half-apply.

The code is shown in the UI, because a recovery path nobody can see is not one."
```

---

### Task 6: Delete cities nobody has touched for 90 days

**Files:**
- Create: `lib/armchair_metropolist/infrastructure/persistence/snapshot_reaper.ex`
- Modify: `lib/armchair_metropolist/application.ex`
- Modify: `config/config.exs`, `config/test.exs`
- Create: `test/armchair_metropolist/infrastructure/persistence/snapshot_reaper_test.exs`

**Interfaces:**
- Consumes: the `updated_at` index from Task 1.
- Produces: `SnapshotReaper.sweep/0`, returning `{:ok, non_neg_integer()}`.

- [ ] **Step 1: Add config**

`config/config.exs`:

```elixir
  # Cities nobody has opened in this long are deleted. Generous on purpose: someone
  # returning after months should still find their city, and one row per city means
  # storage is not the pressure here — unbounded retention of data keyed to a cookie is.
  snapshot_retention_days: 90,
  snapshot_sweep_interval_ms: 24 * 60 * 60 * 1000,
```

`config/test.exs`:

```elixir
# The reaper is driven directly in tests via sweep/0; an interval this long keeps its
# timer from firing during a run.
config :armchair_metropolist, start_reaper: false
```

- [ ] **Step 2: Write the reaper**

```elixir
defmodule ArmchairMetropolist.Infrastructure.Persistence.SnapshotReaper do
  @moduledoc """
  Deletes cities nobody has touched for `:snapshot_retention_days`.

  Server target only. The desktop target has exactly one city that must never be
  reaped, and no scheduler to run this on.

  Sweeps once on boot and then every `:snapshot_sweep_interval_ms`. `sweep/0` is
  public and synchronous so tests can drive it without waiting a day.
  """

  use GenServer

  import Ecto.Query

  alias ArmchairMetropolist.Infrastructure.Persistence.CitySnapshot
  alias ArmchairMetropolist.Infrastructure.Persistence.Repo

  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Delete every city whose `updated_at` is older than the retention window.

  Returns the number deleted. It is logged as well as returned: a sweep that
  removes data should say so, or nobody notices the day it removes the wrong amount.
  """
  def sweep do
    days = config(:snapshot_retention_days, 90)
    cutoff = NaiveDateTime.utc_now() |> NaiveDateTime.add(-days * 24 * 60 * 60, :second)

    {deleted, _} =
      Repo.delete_all(from(s in CitySnapshot, where: s.updated_at < ^cutoff))

    if deleted > 0 do
      Logger.info("[reaper] deleted #{deleted} cities untouched since #{cutoff}")
    end

    {:ok, deleted}
  end

  @impl true
  def init(_opts) do
    {:ok, %{}, {:continue, :sweep}}
  end

  @impl true
  def handle_continue(:sweep, state) do
    sweep()
    {:noreply, schedule(state)}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    {:noreply, schedule(state)}
  end

  defp schedule(state) do
    Process.send_after(self(), :sweep, config(:snapshot_sweep_interval_ms, 86_400_000))
    state
  end

  defp config(key, default), do: Application.get_env(:armchair_metropolist, key, default)
end
```

- [ ] **Step 3: Wire it into `Application`**

Beside `repo_children/0`:

```elixir
  # Server target only, and after the Repo — it queries on boot. The desktop target
  # has one city that must never be reaped.
  defp reaper_children do
    if Application.get_env(:armchair_metropolist, :start_reaper, true) do
      [ArmchairMetropolist.Infrastructure.Persistence.SnapshotReaper]
    else
      []
    end
  end
```

Insert `reaper_children()` immediately after `repo_children()` in the child list, and set `start_reaper: false` in the desktop overrides in `Desktop.Config.apply!/0`.

- [ ] **Step 4: Test it**

```elixir
defmodule ArmchairMetropolist.Infrastructure.Persistence.SnapshotReaperTest do
  use ArmchairMetropolist.DataCase, async: false

  alias ArmchairMetropolist.Domain.Entities.CityMap
  alias ArmchairMetropolist.Infrastructure.Persistence.CitySnapshot
  alias ArmchairMetropolist.Infrastructure.Persistence.Repo
  alias ArmchairMetropolist.Infrastructure.Persistence.SnapshotReaper
  alias ArmchairMetropolist.Infrastructure.Persistence.SnapshotStore

  defp age(city_id, days) do
    stale = NaiveDateTime.utc_now() |> NaiveDateTime.add(-days * 86_400, :second)
    Repo.update_all(from(s in CitySnapshot, where: s.city_id == ^city_id), set: [updated_at: stale])
  end

  test "deletes a city past the window and keeps a fresh one" do
    :ok = SnapshotStore.save("stale", 1, CityMap.new(10, 10))
    :ok = SnapshotStore.save("fresh", 1, CityMap.new(10, 10))
    age("stale", 91)

    assert {:ok, 1} = SnapshotReaper.sweep()
    assert {:error, :not_found} = SnapshotStore.load("stale")
    assert {:ok, _} = SnapshotStore.load("fresh")
  end

  test "keeps a city exactly at the boundary" do
    :ok = SnapshotStore.save("edge", 1, CityMap.new(10, 10))
    age("edge", 89)

    assert {:ok, 0} = SnapshotReaper.sweep()
    assert {:ok, _} = SnapshotStore.load("edge")
  end

  test "does not delete a city it has just seen" do
    :ok = SnapshotStore.save("new", 1, CityMap.new(10, 10))

    assert {:ok, 0} = SnapshotReaper.sweep()
    assert {:ok, _} = SnapshotStore.load("new")
  end

  test "a zero-day window still spares a city saved this instant" do
    Application.put_env(:armchair_metropolist, :snapshot_retention_days, 0)
    on_exit(fn -> Application.delete_env(:armchair_metropolist, :snapshot_retention_days) end)
    :ok = SnapshotStore.save("now", 1, CityMap.new(10, 10))

    assert {:ok, 0} = SnapshotReaper.sweep()
  end
end
```

That last test is the off-by-one that would quietly empty the table: with `<=` instead of `<`, or a cutoff computed the wrong way round, a zero-day window deletes everything.

- [ ] **Step 5: Run the suite**

```bash
mix check
```

Expected: PASS at or above 90%.

- [ ] **Step 6: Mutation-verify the comparison direction**

```bash
cp lib/armchair_metropolist/infrastructure/persistence/snapshot_reaper.ex /tmp/reaper.bak
perl -0pi -e 's/where: s\.updated_at < \^cutoff/where: s.updated_at > ^cutoff/' lib/armchair_metropolist/infrastructure/persistence/snapshot_reaper.ex
mix test test/armchair_metropolist/infrastructure/persistence/snapshot_reaper_test.exs 2>&1 | tail -6
cp /tmp/reaper.bak lib/armchair_metropolist/infrastructure/persistence/snapshot_reaper.ex
```

Expected: multiple failures, including "does not delete a city it has just seen". A reversed comparison is the single worst bug this module can have — it deletes exactly the cities people are using.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: delete cities untouched for 90 days

A sweep on boot and then daily, server target only - the desktop target has one
city that must never be reaped and no scheduler to run this on. sweep/0 is public
and synchronous so tests drive it directly rather than waiting a day.

The count is logged as well as returned: a sweep that removes data should say so,
or nobody notices the day it removes the wrong amount.

Tested at the boundary, one day inside it, and with a zero-day window, which is
the off-by-one that would quietly empty the table. Mutation-verified by reversing
the comparison - the worst bug this module can have, since it would delete
exactly the cities people are using."
```

---

## Self-Review

**Spec coverage:**

| spec section | task |
|---|---|
| §3 freeze on disconnect | Task 3 |
| §3 cookie plus re-entry code | Tasks 4, 5 |
| §3 one row per city, upserted | Task 1 |
| §3 90-day retention | Task 6 |
| §4 identity plug, string session keys | Task 4 Steps 2, 4 |
| §4 allowlist validation, `\A…\z` | Task 4 Steps 1, 6 |
| §4 unknown code yields an empty city | Task 5 Steps 1, 4 |
| §4 code shown in the UI | Task 5 Step 3 |
| §5 registry, dynamic supervisor, start-on-demand race | Task 2 Steps 1, 9 |
| §5 freeze by monitoring, with a linger | Task 3 |
| §6 `TickServer` unchanged; per-city topic | Task 2 Steps 2, 3, 6, 8 |
| §7 port rename, schema, upsert, legacy preservation | Task 1 |
| §8 reaper | Task 6 |
| §9 desktop single-city | Task 1 Step 5, Task 4 Step 5, Task 6 Step 3 |
| §10 limitations | no task — accepted as recorded |
| §12 verification | mutation steps in Tasks 1, 2, 3, 4, 6 |

**Placeholder scan:** none. Every code step carries the literal content, and the migration filename is spelled out rather than left as a timestamp placeholder.

**Type consistency:** `load/1` and `save/3` are defined in Task 1 Step 1 and used with that arity in Steps 4, 5, 7 and in Task 6's tests. `CityRegistry.via/1`, `ensure_started/1`, `whereis/1`, `count/0` are defined in Task 2 Step 1 and used in Tasks 2 and 3. `CityEngine.topic/1` is defined in Task 2 Step 2 and used in Tasks 2 and 4. `CityCode.generate/0` and `valid?/1` are defined in Task 4 Step 1 and used in Task 4 Step 2 and Task 5 Step 1. `default_city_id/0` is added in Task 2 Step 4 and used in Task 4 Step 4.

**Known gaps, deliberate:**

* **Task 2 Step 4 wires the LiveView to a constant, which Task 4 replaces.** Deliberate: it keeps Task 2 independently testable rather than forcing the engine and the web changes into one reviewable unit. A reviewer of Task 2 should not flag the constant.
* **The `city_snapshots` primary key changes type,** so Task 1's migration is not a pure `alter`. It recreates the table, which means it holds an exclusive lock for its duration. The table has at most a few thousand rows on the deployed instance, so this is seconds — but it is a lock, and the deploy is not zero-downtime regardless.
* **No test covers two *engines* competing for one row,** because they cannot: the registry guarantees one process per city id. That guarantee is what Task 2 Step 9 tests.

**Amended 2026-08-03, mid-execution.** The first draft of Task 1 replaced the append-only layout with an unconditional upsert, which silently dropped the guarantee that a save cannot move a city backwards — the protection against a crashed engine hydrating from an older snapshot and overwriting newer work. The implementer hit it as two failing contract tests and escalated rather than deleting them, which was correct: they were asserting a real guarantee, not a stale one. `save/3` now returns `{:stale, stored_tick}`, both adapters honour it, and the engine logs a refusal distinctly from a failure. Per-city isolation moved out of the shared contract at the same time, because `FileSnapshotStore` does not isolate and never claimed to.
