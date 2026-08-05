# Armchair Metropolist

An urban infrastructure simulation game.

A city of power plants, water plants, industrial and commercial blocks, transit hubs,
parks and residential blocks ticks forward in real time. Each tick recomputes six
resources — power, water, waste, traffic, labour and money — as supply against
demand; starved nodes lose health and eventually go offline, which removes their
contribution and starves the rest of the city further. Money is the one resource
whose surplus survives the tick boundary, so a city can read fully satisfied on the
other five and still be quietly going broke.

Every visitor gets their own city. A 22-character code in the signed session cookie
identifies it, the page shows the code, and `/c/<code>` re-enters that city from
another browser. Each city runs its own simulation process, started on demand and
stopped a short while after the last viewer leaves. The grid updates live over
LiveView, and a city survives both that stop and a restart via periodic compressed,
checksummed snapshots; a city untouched for 90 days is reaped.

It runs two ways from one codebase: as a web app backed by Postgres, and as a
native desktop app with no database at all.

## Running the web app locally

Needs Elixir 1.19.3+ (this project develops on 1.20.2 / OTP 29) and a local Postgres.

```bash
mix setup
mix phx.server
```

Then open <http://localhost:4000>. `mix setup` fetches dependencies, creates and
migrates the database, and builds the CSS and JS.

## Running the desktop app

The desktop build wraps the same Phoenix app in a [Tauri](https://tauri.app)
window. Instead of Postgres it keeps the city in a file under the OS
application-data directory, and alerts go to the native notification centre. There
is exactly one city there — no re-entry code is shown, and nothing reaps it.

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

## Installing a release

The bundles above are what a build produces locally. To just *run* it, take a
built one from the [releases page](https://github.com/adsouza/armchair-metropolist/releases).

Linux, x86_64:

```bash
sudo apt install ./armchair-metropolist_<version>_amd64.deb
```

There is no aarch64 `.deb` yet — nobody has asked, and that leg would need a
from-source Tauri CLI build.

Or, on any distribution with Flatpak:

```bash
flatpak install --user ./armchair-metropolist_<version>_x86_64.flatpak
flatpak run io.github.adsouza.armchair-metropolist
```

**Take this one if your distribution is older than Ubuntu 24.04.** The `.deb`
inherits the glibc of the machine that built it — it declares `libc6 (>= 2.39)`,
so it will not install on Debian 13 or anything older. The Flatpak brings its own
userspace and does not care; it needs the `org.gnome.Platform` 50 runtime, which a
current GNOME desktop already has and which Flatpak will otherwise fetch.

It runs with **no network access at all**. A Flatpak without `--share=network`
still gets loopback, which is all the app uses — the server and the window talk to
each other over `127.0.0.1` and nothing else.

It is side-loaded rather than installed from Flathub, so it will not auto-update.
`flatpak install` the next release over the top.

`armchair-metropolist-server_<version>_linux-x86_64` (and `…_linux-aarch64`) is also
attached. That is the Burrito sidecar the desktop app runs internally: a single file
carrying its own Erlang runtime, which serves the app in a browser instead of a native
window. Useful for trying it on a machine you would rather not install a package on,
including aarch64, which gets no `.deb`.

```bash
chmod +x armchair-metropolist-server_<version>_linux-x86_64
ARMCHAIR_DESKTOP=1 PORT=4000 \
  SECRET_KEY_BASE="$(head -c 48 /dev/urandom | base64)" \
  ./armchair-metropolist-server_<version>_linux-x86_64 --no-halt
```

Then open `http://127.0.0.1:4000`. Three parts of that are load-bearing and none are
guessable:

* **`chmod +x`** — a release asset is an HTTP download and carries no permission bit, so
  it always arrives non-executable however it was built.
* **`--no-halt`** — Burrito launches the release as `erl -noshell -s elixir start_cli`,
  which treats trailing arguments as scripts and then halts. Without it the sidecar boots
  Phoenix, prints that it is running, and exits 0. (`… start` does not work either: it
  tries to *run* a file named `start`.)
* **`ARMCHAIR_DESKTOP=1`** — selects the file-backed single-city store. Without it this
  binary is the server target and expects `DATABASE_URL` and a Postgres to talk to.

It binds **loopback only** and disables origin checking, which is a safe pair precisely
because it is loopback. It is not a way to host the app for other people — that is what
the Gigalixir deploy is for.

## Cutting a release

The version lives in five files and they must agree, so move them together
rather than by hand. One of them, the Flatpak's AppStream metainfo, holds a
release *list* — the changelog a software centre shows — so the task prepends
to it rather than overwriting, and dates the entry today:

```bash
mix version.set 0.2.0
git commit -am "Release 0.2.0" && git push
git tag v0.2.0 && git push origin v0.2.0
```

The tag is checked against the declared version in CI, so a tag that disagrees
fails before anything is published — as does a tag whose shape is wrong, such as
`v0.2` or a full `refs/tags/…` ref.

Bumping the version is not bookkeeping. A production Burrito binary unpacks its
payload once, keyed on the app version, so two packages sharing a version means
the second one installs code that never runs. That is why the tag drives the
release rather than merely labelling it.

## Actually playing it

There are two ways to lose, and your first city will almost certainly find the fast
one: baseline capacity supports exactly **two** residential blocks, and the third
starts a death spiral that cannot be reversed by building more.

The slow one is insolvency. Four resources have a free baseline of 40; labour and
money have none, and a city opens with a one-off 500 in the treasury. A support set
without a commercial block cannot cover its own upkeep, so the treasury drains for
the whole game while every other resource reads 100% satisfied — commercial is part
of the ratio, not an optional extra.

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

**Nothing in the deploy runs migrations — you must run them by hand.** Neither the
buildpacks nor the supervision tree will do it for you, and a deploy carrying a new
migration fails in a way that reads as healthy: no city engine starts at boot, so the
app comes up, passes its health checks, and then raises on the first visitor's
hydrate. Run:

```bash
gigalixir run -a armchair-metropolist bin/armchair_metropolist eval 'ArmchairMetropolist.Release.migrate()'
```

`gigalixir run` starts a separate container that does not run the supervision tree.
Cities recover by themselves once the migration lands. The rest of the configuration
and how to verify a deploy are in [`docs/deploying.md`](docs/deploying.md) — worth
reading before your first deploy.

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

[`ARCHITECTURE.md`](ARCHITECTURE.md) has the layer diagram, the split between the
clock and the per-city engines, how snapshots are encoded, and what the compiler will
refuse to let you write. The design and its deliberate deviations from the original brief are
recorded in [`docs/superpowers/specs/`](docs/superpowers/specs/).
