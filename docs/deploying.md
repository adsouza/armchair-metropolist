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
with no restart or further action needed. Run it straight after the merge that
carries the migration lands on main — deploys are CI-driven (see "Continuous
deployment"), so there is no `git push gigalixir` moment to attach this to any more;
the human act a migration rides along with is *merging the PR that contains it*, and
with the boot crash gone there is no wall of red to tell you that you forgot.

This is the one post-deploy step that is still manual. The vocabulary trap below
used to be the other, until the 2026-08-05 outage — a green CI deploy shipped a
rename and nobody was at a terminal to run its follow-up — moved its remedy into
code. Automating this one the same way means making `gigalixir run`'s success or
failure observable from the deploy job, which has not been established; do not wire
it in without proving that first.

### Why this is not fixed in the engine

Making hydration tolerate a failed snapshot load and start a fresh city would be
worse than the crash. A *transient* database error would then silently produce an
empty city, and the next checkpoint would overwrite the good snapshot with it —
turning a brief outage into permanent data loss. "No snapshot exists yet" already
starts a fresh city and is not an error; "the snapshot cannot be read" must stay
fatal. The ordering belongs in the deploy, not in a `rescue`.

## The other trap: renaming a node type

**A rename is completed by adding one entry to `@node_type_renames` in
`Infrastructure.Persistence.SnapshotVocabulary`.** That is the whole procedure: no
purge, no migration file, and nothing to run on anyone's desktop install.

Why there is a procedure at all: a stored city is made of atoms, and both snapshot
adapters decode with `:safe`, which refuses to *create* them. Retire an atom — rename
or remove a value in `Domain.Entities.Node`'s `node_type` or `status` vocabulary — and
every row or snapshot file written before the change stops decoding. On the server
that is the *unreadable* case, deliberately fatal per the section above: the returning
visitor's engine crash-loops in `handle_continue(:hydrate, …)` behind passing health
checks, and they get a 500 while a fresh session gets a 200. On the desktop it is
quieter and worse: `FileSnapshotStore` rescues the decode to `:malformed`, the engine
silently starts over, and the stale file's envelope tick — which still decodes, its
atoms being the envelope's own — blocks every subsequent save through
`save_current/2`'s older-tick refusal. At 1 tick/second, a snapshot at tick 5550 means
~92 minutes of unbroken play before anything persists again. (That refusal is not the
bug: it exists to stop a *transient* load miss from destroying a good city. The stale
file is the bug.)

The rename map fixes both at the layer that owns them. Its literal keys keep the
retired atoms interned, so `:safe` accepts them; `SnapshotVocabulary.modernize/1`,
called by both adapters on every decoded payload, rewrites them to their successors.
A snapshot written before the rename hydrates as though it had been written after it.
There is nothing to reach into installed desktop copies for, which matters now that
released versions exist.

**Forgetting the entry is what the test suite now catches.** An earlier version of
this section prescribed `DELETE FROM city_snapshots` "straight after the push", and
claimed no test could catch the omission because "the only disagreeing copies of the
old vocabulary are rows on the server". Both failed together on 2026-08-05: deploys
had become CI-driven, no human was present at push time, the purge was never run, and
a stored city 500'd every visit by its owner. The answer to the second claim is
committed binary fixtures — payloads written under an old vocabulary that the compiler
cannot see into, decoded by `snapshot_vocabulary_test.exs` on every run:

* `test/support/fixtures/city_snapshot_pre_transit_hub_rename.bin` is the actual
  payload behind the 2026-08-05 outage, and keeps the `road_hub → transit_hub` rename
  honest permanently.
* `test/support/fixtures/city_snapshot_vocabulary_coverage.bin` pins every node type
  and status the code currently ships. Retiring one without a rename entry turns the
  suite red — in CI, before the change can reach a stored row it cannot read.
  Regenerate it only when the vocabulary *gains* an atom, using
  `generate_coverage_fixture.exs` beside it; the test's equality check against
  `Node.types/0` and `Node.statuses/0` goes red to remind you. Never spell a retired
  atom as a literal in a test: it would re-intern it and disarm the decode the
  fixtures exist to exercise (the test file's header comment explains).

If a rename map entry ever needs to be dropped (say, to finally let `road_hub` go),
that *is* a data migration again: purge or rewrite the stored rows first, and delete
the pre-rename fixture with it.

For debugging a desktop install, the snapshot files live in `ExTauri.Paths.data_dir()`
— named from `:app_name` in `config/config.exs` ("Armchair Metropolist" →
`armchair_metropolist`): `~/Library/Application Support/armchair_metropolist/` on
macOS, `~/.local/share/armchair_metropolist/` on Linux. It is *not* the
`io.github.adsouza.armchair-metropolist` directory beside it, which holds Tauri's
window state.

## The third trap: rolling back past a new CityMap field

`waste_stock` was added to `CityMap` on 2026-08-07. Snapshots written from that
commit onward contain the `:waste_stock` atom, and a binary built before it
cannot decode them — `:safe` will not create an atom the release does not
already have. Rolling back past that commit strands every city written since:
the server crash-loops on hydrate, the desktop app starts an empty grid.

`dcd1ee4` is the minimum rollback target. Any future field added to a
persisted struct has the same one-way property, and the safe pattern is two
releases — one that interns the atom without writing it, then the writer.

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
