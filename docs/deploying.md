# Deploying

Two targets ship from this repository:

* the **server**, an Elixir release deployed to Gigalixir, and
* the **desktop** app, a Burrito-wrapped sidecar inside Tauri. Its own traps are
  in [`superpowers/2026-07-30-follow-ups.md`](superpowers/2026-07-30-follow-ups.md)
  — read that before touching `mix ex_tauri.build`.

## The trap: nothing runs your migration, and the broken deploy looks healthy

**Read this before deploying a change that includes a new migration.** No part of
the deploy applies one: not the buildpacks, not the supervision tree, and not CI
(see "Continuous deployment" below). You run it, by hand, every time.

`CityEngine` hydrates from the database in `handle_continue(:hydrate, …)`. If a
migration it depends on has not been applied, `SnapshotStore.load/1` raises
— `Repo.get/2` raises on a missing table rather than returning `{:error, _}`, so
hydration's `{:error, reason}` arm is not a failure path here — and the engine dies.

**The deploy will still look fine.** Since the 2026-08-03 per-visitor change, no
engine starts at boot: `Application` starts the `Registry` and `DynamicSupervisor`
that name them, and `CityRegistry.ensure_started/1` starts an actual engine only
when somebody asks for a city. So the container boots, the endpoint serves, health
checks pass, and nothing touches `city_snapshots` until the first visitor arrives —
at which point their engine crashes, is restarted by the `DynamicSupervisor`
(`restart: :transient` restarts a crash; only a `:normal` stop sticks), and crashes
again. Every visitor repeats it.

> The old version of this section described the failure as an immediate boot
> crash-loop that took the endpoint down with it. That was accurate when the engine
> was a boot child of `ArmchairMetropolist.Supervisor`; it no longer is. How far the
> restart cascade climbs from the `DynamicSupervisor` toward the application
> supervisor under real traffic has **not** been measured since the change — do not
> rely on either "it stays up" or "it comes down". Rely on: run the migration.

`gigalixir ps:migrate` works over SSH into a running replica, and it needs a host
key someone has to accept interactively the first time — so it is not something a
script or CI can do for you. Its own error message suggests `gigalixir run mix
ecto.migrate`, which is also wrong for this app: it is a release build, so Mix does
not exist inside it.

Use `gigalixir run`, which starts a **separate** container that does not run the
supervision tree, so the missing table cannot stop it:

```bash
gigalixir run -a armchair-metropolist bin/armchair_metropolist eval 'ArmchairMetropolist.Release.migrate()'
```

It self-heals: once the migration lands, the next engine to start hydrates cleanly,
with no restart or further action needed. Run it straight after
`git push gigalixir main` rather than waiting for the rollout to settle — with the
boot crash gone, there is no longer a wall of red to tell you that you forgot.

### Why this is not fixed in the engine

Making hydration tolerate a failed snapshot load and start a fresh city would be
worse than the crash. A *transient* database error would then silently produce an
empty city, and the next checkpoint would overwrite the good snapshot with it —
turning a brief outage into permanent data loss. "No snapshot exists yet" already
starts a fresh city and is not an error; "the snapshot cannot be read" must stay
fatal. The ordering belongs in the deploy, not in a `rescue`.

## The other trap: renaming a node type is a data migration

**Read this before deploying a change that renames or removes a value in
`Domain.Entities.Node`'s `node_type` or `status` vocabulary.** A stored city is made of
atoms, and both snapshot adapters decode with `:safe`, which refuses to *create* them —
see `Infrastructure.Persistence.SnapshotVocabulary`. The old value only decodes because
loading `Node` interns it. Complete the rename and nothing interns it any more, so every
row written before the deploy raises `ArgumentError` on decode.

That is the *unreadable* case, not the *absent* case, so by the section above it is
deliberately fatal: the visitor's engine dies in `handle_continue(:hydrate, …)`, the
`DynamicSupervisor` restarts it, and it dies again. Nothing else notices — the container
boots and health checks pass, exactly as with a missing migration.

Nothing in CI or in the test suite can catch this. The compiler sees a consistent
codebase and every fixture is written by the new code; the only disagreeing copies of the
old vocabulary are rows on the server.

Stored cities are per-visitor sandboxes that `SnapshotReaper` already deletes on a
retention window, so the answer is to drop them rather than carry migration code for a
term that self-deletes. Straight after the push:

```bash
gigalixir pg:psql -a armchair-metropolist -c 'DELETE FROM city_snapshots'
```

Every visitor then starts a fresh city, which is the not-an-error path. Do this as its
own step rather than as an Ecto migration: migrations are run by hand here anyway (above),
so a migration would add a file to maintain without removing a manual step.

If a stored city ever becomes worth preserving, the alternative is to keep the retired
atom interned — a `@legacy_atoms` list in `SnapshotVocabulary` — and rewrite it to the new
one as `CityMap` hydrates. That is real code and wants a test that decodes a payload built
from the old vocabulary; do not add it speculatively.

### The desktop target needs purging too, and it fails silently

`FileSnapshotStore` returns rather than raises (see its "Failures are returned, never
raised"), so the desktop app does **not** crash-loop. It does something quieter and worse.
Measured, not inferred:

1. `load_current/0` rescues both files to `:malformed` and reports `{:error, :not_found}`.
   The engine starts a fresh city at tick 0. Nothing is logged.
2. `save/3` sees that `:not_found`, so its own staleness guard does not fire, and it calls
   `save_current/2`.
3. `save_current/2`'s `stale?/1` reads the tick from the **envelope**, which decodes fine:
   the envelope's atoms are `:version`, `:tick`, `:checksum`, `:payload`, and the city stays
   an opaque binary inside it. So it reports the *old* high tick.
4. `old_tick > new_tick`, so it returns `:ok` **without writing**. The engine is told the
   checkpoint succeeded.

The result is an app that looks fine and persists nothing. Every launch starts over, and no
save lands until one unbroken session's tick exceeds the stored tick — at 1 tick/second, a
snapshot at tick 5550 means ~92 minutes of play before the first successful write.

Note the irony before changing `save_current/2` to "fix" it: the older-tick refusal exists
precisely to stop a *transient* load miss from demoting a good city into the backup and then
overwriting that too. A retired atom makes the miss permanent, and the safeguard becomes the
thing blocking recovery. The bug is the stale file, not the guard.

So a node-type rename also has to purge each installed copy — there is no deploy step that
can reach them:

```bash
rm ~/Library/Application\ Support/armchair_metropolist/snapshot.{bin,bak}   # macOS
rm ~/.local/share/armchair_metropolist/snapshot.{bin,bak}                   # Linux
```

The directory is `ExTauri.Paths.data_dir()`, named from `:app_name` in `config/config.exs`
("Armchair Metropolist" → `armchair_metropolist`). It is *not* the
`io.github.adsouza.armchair-metropolist` directory beside it, which holds Tauri's window
state. For a released version this is a reason to prefer the `@legacy_atoms` shim above:
you cannot ask every install to run `rm`.

## Deploying the server

```bash
gigalixir git:remote -a armchair-metropolist   # once, per clone
git push gigalixir main
```

Gigalixir builds an Elixir release, because `.gigalixir/mix` is deliberately absent.
The pieces that make that work, all of which are load-bearing:

| file                                | why                                                                                                                  |
|-------------------------------------|----------------------------------------------------------------------------------------------------------------------|
| `.tool-versions`                    | the builder has no other reason to provide the Elixir ≥ 1.19.3 `mix.exs` requires                                    |
| `.buildpacks`                       | elixir + releases only; the phoenix-static buildpack is for npm assets and this project has no `assets/package.json` |
| `default_release:` in `mix.exs`     | the buildpack runs a bare `mix release`, and Mix refuses to choose between `armchair_metropolist` and `desktop`      |
| release name `armchair_metropolist` | the releases buildpack starts `/app/bin/<otp app name>`                                                              |
| `deploy_assets/1` release step      | `:assemble` only *copies* `priv/static`, which is gitignored, so without this the app serves no CSS or JS            |

### Configuration

Set on Gigalixir, never committed — this repository is public.

| var               | notes                                                                                                                                                                                                           |
|-------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `DATABASE_URL`    | set automatically by `gigalixir pg:create`                                                                                                                                                                      |
| `POOL_SIZE`       | must be ≤ 4. The free-tier role has `rolconnlimit = 4`, so the generated default of 10 cannot open and the app dies on "too many connections for role". `config/runtime.exs` defaults to 2                      |
| `SECRET_KEY_BASE` | `gigalixir config:set -a armchair-metropolist SECRET_KEY_BASE="$(mix phx.gen.secret)"` — generates it locally so it never passes through anything else                                                          |
| `PHX_HOST`        | **not cosmetic.** Phoenix's default `check_origin: true` compares a socket's `Origin` against this host, so the generated `example.com` fallback renders the page and then rejects the LiveView socket with 403 |

`PHX_SERVER` is deliberately **not** required: `config/runtime.exs` sets
`server: true` outright for this target, because a server release exists in order
to serve and gating that on an environment variable turns one omission into a
crash-looping deploy with nothing to read.

Database TLS verifies against a pinned CA in `priv/cert/gigalixir-ca.pem`, since
Gigalixir signs with their own root rather than a public one. `DATABASE_SSL=false`
disables TLS for a Postgres that does not offer it;
`DATABASE_SSL_CACERTFILE` overrides the path if that root is ever rotated.

## Verifying a deploy

`curl` negotiates HTTP/2 over TLS, and a WebSocket `Upgrade:` header is HTTP/1.1
only — so a socket check without `--http1.1` returns 400 and looks like a broken
app. Check the negative case too: a 101 proves nothing about origin checking unless
a bad origin is refused.

```bash
URL=https://armchair-metropolist.gigalixirapp.com
curl -s -o /dev/null -w '%{http_code}\n' $URL/                       # 200
curl -s -o /dev/null -w '%{http_code}\n' --http1.1 \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  -H "Origin: $URL" "$URL/live/websocket?vsn=2.0.0"                  # 101
curl -s -o /dev/null -w '%{http_code}\n' --http1.1 \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  -H 'Origin: https://evil.example.com' "$URL/live/websocket?vsn=2.0.0"  # 403
```

## Continuous deployment

`.github/workflows/ci.yml` deploys to Gigalixir on a green build, gated on a push
to `main` — never from a pull request, and never in parallel with the test job. It
does not run migrations: see the trap above.
