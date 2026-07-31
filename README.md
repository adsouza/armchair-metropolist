# Armchair Metropolist

An urban infrastructure simulation game.

A city of power plants, water plants, waste facilities, road hubs and residential
blocks ticks forward in real time. Each tick recomputes resource supply against
demand; starved nodes lose health and eventually go offline, which removes their
contribution and starves their neighbours further. The grid updates live over
LiveView, and the city survives restarts via periodic compressed, checksummed
snapshots.

It runs two ways from one codebase: as a web app backed by Postgres, and as a
native desktop app with no database at all.

## Running the web app locally

Needs Elixir 1.18+ (this project develops on 1.20.2 / OTP 29) and a local Postgres.

```bash
mix setup
mix phx.server
```

Then open <http://localhost:4000>. `mix setup` fetches dependencies, creates and
migrates the database, and builds the CSS and JS.

## Running the desktop app

The desktop build wraps the same Phoenix app in a [Tauri](https://tauri.app)
window. Instead of Postgres it keeps the city in a file under the OS
application-data directory, and alerts go to the native notification centre.

Extra prerequisites: **Rust/Cargo** and **Zig 0.16** — Burrito shells out to
`zig build` for every build, native ones included.

```bash
mix ex_tauri.dev
```

That opens a window against a live-reloading dev server, which is the fastest loop
for UI work.

To build a distributable bundle:

```bash
mix ex_tauri.build
```

This produces, on macOS:

* `src-tauri/target/release/bundle/macos/Armchair Metropolist.app`
* `src-tauri/target/release/bundle/dmg/Armchair Metropolist_<version>_aarch64.dmg`

Launch the built app with:

```bash
open "src-tauri/target/release/bundle/macos/Armchair Metropolist.app"
```

Two things to know before you debug a desktop build:

* **Always rebuild with `mix ex_tauri.build`**, never a bare `cargo build
  --release` — that empties the bundle's `Contents/MacOS/` and invalidates
  everything you are about to check.
* Linux binaries need a Linux runner. Cross-compiling them from macOS fails at
  Zig's link step; CI builds each Linux architecture natively instead.

The traps that cost real time here — chiefly that a production Burrito binary
unpacks its payload only once, so rebuilds are silent no-ops at runtime unless the
cache is evicted — are written up in
[`docs/superpowers/2026-07-30-follow-ups.md`](docs/superpowers/2026-07-30-follow-ups.md).

## Actually playing it

The simulation is unforgiving in one specific way, and your first city will almost
certainly collapse: baseline capacity supports exactly **two** residential blocks, and
the third starts a death spiral that cannot be reversed by building more.

[`docs/PLAYING.md`](docs/PLAYING.md) explains why, what a working support set looks
like, and how to rescue a city that is already dying — plus the production and
consumption tables. Its numbers are generated from the domain code and checked by a
test, so they cannot drift away from the rules.

## Deploying to Gigalixir

```bash
gigalixir git:remote -a armchair-metropolist   # once per clone
git push gigalixir main
```

Gigalixir builds an Elixir release and starts it. Four config vars must be set on
the app — never committed, as this repository is public:

```bash
gigalixir config:set -a armchair-metropolist SECRET_KEY_BASE="$(mix phx.gen.secret)"
gigalixir config:set -a armchair-metropolist PHX_HOST=armchair-metropolist.gigalixirapp.com
```

`DATABASE_URL` and `POOL_SIZE` are set for you by `gigalixir pg:create --free`.
`PHX_HOST` is not cosmetic: Phoenix checks a LiveView socket's origin against it,
so leaving it unset renders the page and then refuses the socket.

**If your deploy includes a new migration, it will crash-loop until you run it**,
and `gigalixir ps:migrate` cannot help because it needs a running replica. Use:

```bash
gigalixir run -a armchair-metropolist bin/armchair_metropolist eval 'ArmchairMetropolist.Release.migrate()'
```

It recovers by itself once the migration lands. The full explanation, the rest of
the configuration, and how to verify a deploy are in
[`docs/deploying.md`](docs/deploying.md) — worth reading before your first deploy.

## Tests

```bash
mix check
```

That is the project's whole quality gate, and what to run before committing: a
format check, a forced warnings-as-errors recompile — which is also what makes
[`boundary`](https://github.com/sasa1977/boundary) violations fail, since they are
only warnings — and the full suite under coverage, gated at 90%.

`mix setup` also installs git hooks from `.githooks/`, so you do not have to
remember: `pre-commit` runs the fast checks plus a scan of the staged diff for
credentials (this repository is public), and `pre-push` runs the whole gate. Run
`mix githooks` if you cloned before they existed.

[`TESTING.md`](TESTING.md) covers the rest: running a subset, what the suite is made
of and why it is shaped that way, the manual checks for each target, how to
mutation-test a change by hand, and how to check the hooks still bite.

## Architecture

Clean/Hexagonal, enforced at compile time by `boundary` rather than by convention.
`Domain` is pure and depends on nothing; it declares ports (`SnapshotRepository`,
`Notifier`) that `Infrastructure` implements, so the dependency arrow points
inward and the compiler rejects a violation. Swapping Postgres for a file on the
desktop target is a config change, not a code change.

[`ARCHITECTURE.md`](ARCHITECTURE.md) has the layer diagram, the two-process
simulation design, how snapshots are encoded, and what the compiler will refuse to
let you write. The design and its deliberate deviations from the original brief are
recorded in [`docs/superpowers/specs/`](docs/superpowers/specs/).
