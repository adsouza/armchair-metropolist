# Deploying

Two targets ship from this repository:

* the **server**, an Elixir release deployed to Gigalixir, and
* the **desktop** app, a Burrito-wrapped sidecar inside Tauri. Its own traps are
  in [`superpowers/2026-07-30-follow-ups.md`](superpowers/2026-07-30-follow-ups.md)
  — read that before touching `mix ex_tauri.build`.

## The trap: a deploy that adds a migration will crash-loop until you run it

**Read this before deploying a change that includes a new migration.**

`CityEngine` hydrates from the database in `handle_continue(:hydrate, …)`, which
runs during application start. If a migration the engine depends on has not been
applied yet, `SnapshotStore.load_latest/0` raises, the engine dies, and it dies
again on every restart until the supervisor exceeds its restart intensity and takes
the whole application down with it. The container exits 1, Gigalixir restarts it,
and the cycle repeats.

Two things make this more confusing than it should be:

1. **The endpoint starts first and logs success.** You will see
   `Running ArmchairMetropolistWeb.Endpoint with Bandit … at :::4000` and
   `Access … at https://…` in the logs immediately before the crash, which reads
   like a healthy boot. It is not: the endpoint and the engine are siblings under
   `ArmchairMetropolist.Supervisor`, and the engine's failure brings the endpoint
   down with it. The next lines are `Application armchair_metropolist exited:
   shutdown` and `Your app is failing health checks`.
2. **`gigalixir ps:migrate` cannot help you**, because it works over SSH into a
   running replica and there is no running replica. Its own error message suggests
   `gigalixir run mix ecto.migrate`, which is also wrong for this app — it is a
   release build, so Mix does not exist inside it.

Use `gigalixir run`, which starts a **separate** container that does not run the
supervision tree, so the missing table cannot stop it:

```bash
gigalixir run -a armchair-metropolist bin/armchair_metropolist eval 'ArmchairMetropolist.Release.migrate()'
```

It self-heals: once the migration lands, the next automatic restart hydrates
cleanly and the app comes up with no further action. Observed on the first deploy —
crashes at `10:48:18` and `10:48:37`, migration at `10:48:38`, healthy thereafter.
If you would rather not watch a few minutes of red, run the command above straight
after `git push gigalixir main` instead of waiting for the rollout to settle.

### Why this is not fixed in the engine

Making hydration tolerate a failed snapshot load and start a fresh city would be
worse than the crash. A *transient* database error would then silently produce an
empty city, and the next checkpoint would overwrite the good snapshot with it —
turning a brief outage into permanent data loss. "No snapshot exists yet" already
starts a fresh city and is not an error; "the snapshot cannot be read" must stay
fatal. The ordering belongs in the deploy, not in a `rescue`.

## Deploying the server

```bash
gigalixir git:remote -a armchair-metropolist   # once, per clone
git push gigalixir main
```

Gigalixir builds an Elixir release, because `.gigalixir/mix` is deliberately absent.
The pieces that make that work, all of which are load-bearing:

| file                                | why                                                                                                                  |
|-------------------------------------|----------------------------------------------------------------------------------------------------------------------|
| `.tool-versions`                    | the builder has no other reason to provide the Elixir ≥ 1.18 `mix.exs` requires                                      |
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
