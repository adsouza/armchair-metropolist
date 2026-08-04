# A Flatpak bundle in CI — design

## 1. Problem

`docs/superpowers/specs/2026-08-02-linux-desktop-bundle-design.md` §11 deferred Flatpak and named two
conditions for revisiting: the deb pipeline green, and "the release-versioning policy that risk 2
depends on". Both are now met — `2026-08-03-tag-driven-releases-design.md` shipped, and a `v*` tag
cuts a Release carrying the x86_64 `.deb`.

What Flatpak adds over that `.deb`: it runs on distributions whose glibc is older than the runner's
2.39 (Debian 13, older Ubuntu LTS, Fedora, Arch), because the app no longer inherits the build
machine's userspace. It is also the only route to Flathub, which is where discovery and
auto-updates live.

§11's standing objection remains true and is accepted rather than answered: a `.flatpak` file that is
not on Flathub has to be side-loaded, which for a person who can already `apt install` the `.deb` is
worse. **This design does not claim to improve distribution.** It builds and *proves* the artifact so
that Flathub becomes a paperwork problem rather than an engineering one, and it closes the glibc
question §11 left open with a check that actually executes the binary.

## 2. Measured starting position

Everything here was verified rather than assumed, on 2026-08-04.

**The runtime's glibc — §11's first risk, now settled.** §11 proposed `org.gnome.Platform//46` and
flagged its glibc as "the first thing to establish". It was right to worry, and the answer is that
`//46` was never viable:

| GNOME Platform | freedesktop-sdk (from `gnome-build-meta`) | glibc | Clears `libc6 (>= 2.39)`? |
|---|---|---|---|
| 50 (current stable, released 2026-03-18) | 25.08.15 | ≥ 2.40 | yes |
| 49 | 25.08.15 | ≥ 2.40 | yes |
| 48 | 24.08.34 | 2.40 | yes |
| **46 — what §11 proposed** | 23.08 | ~2.37 | **no** |

Read from `elements/freedesktop-sdk.bst` on each `gnome-build-meta` branch. glibc is
backward-compatible, so a binary built against the runner's 2.39 runs on the runtime's 2.40; the
reverse — which `//46` would have been — dies at the dynamic loader while `flatpak-builder` exits 0.

**Provenance, because the rows are not equally solid.** The freedesktop-sdk *pins* are read directly
from each branch and are facts. glibc **2.40 for 24.08 is stated by that series' release notes**. The
`≥ 2.40` for 25.08 is **inferred** from it being a later series, not measured — it is certainly not
*older*, which is all this design needs, but nobody should later quote it as a verified figure. §7's
mutation 7 is what actually settles the question, by running the binary rather than reading a table.

**The runner ships no Flatpak tooling.** `flatpak`, `flatpak-builder`, `bubblewrap` and `ostree` are
all absent from GitHub's `ubuntu-24.04` image readme. Probed with controls in both directions
(`Docker`, `Podman`, `Git`, `Python` found; an invented string absent), so the silence is evidence
rather than a broken grep. `sudo apt-get install -y flatpak flatpak-builder` is required; `flatpak`
pulls `bubblewrap` and `ostree` in as dependencies.

**The app ID needs no change.** Flatpak IDs must be valid D-Bus names, and Flatpak's own conventions
page says a dash "isn't allowed except in the last component". Our Tauri identifier
`io.github.adsouza.armchair-metropolist` carries its only dash in the final component, so it is valid
as-is. The Flatpak and Tauri identifiers stay identical and macOS signing is untouched.

**Exactly what the `.deb` ships**, from `dpkg-deb --contents` on the real artifact
(`Armchair Metropolist_0.1.0_amd64.deb`, 22 MB, run 30871…):

```
usr/bin/armchair_metropolist                                  <- the Tauri host
usr/bin/desktop                                               <- the Burrito sidecar
usr/share/applications/Armchair Metropolist.desktop           <- note the space
usr/share/icons/hicolor/128x128/apps/armchair_metropolist.png
usr/share/icons/hicolor/256x256@2/apps/armchair_metropolist.png
usr/share/icons/hicolor/32x32/apps/armchair_metropolist.png
```

and the desktop entry itself:

```ini
[Desktop Entry]
Categories=
Exec=armchair_metropolist
StartupWMClass=armchair_metropolist
Icon=armchair_metropolist
Name=Armchair Metropolist
Terminal=false
Type=Application
```

**The `.deb`'s own filename contains a space.** Every path handling it must be quoted. The release
job already quotes `"$DEB"`; the manifest must too.

## 3. Scope

In: an `x86_64` `.flatpak` single-file bundle, built in the existing `release` job and attached to
each Release, against `org.gnome.Platform//50`.

Out, and stated so nobody reads this as half-done:

* **Flathub submission.** Separate, review-gated, and not automatable.
* **Signing.** Flathub signs on its own infrastructure; a side-loaded bundle is trusted by the person
  who downloads it, exactly like the `.deb`.
* **aarch64.** There is no aarch64 `.deb` to repackage — declined in the releases design for the same
  reason, that the leg needs a from-source Tauri CLI build for an audience of nobody so far.
* **Building on pushes to `main`.** ~~The runtime pull is 1.5–2 GB and uncacheable against a
  repository budget already holding four mix caches. At release cadence that is affordable; per merge
  it is not.~~

  **That reasoning was wrong, measured 2026-08-04.** On a hosted runner the runtime and SDK install
  in **50 seconds** (`real 0m50.415s`, peaking at 32.2 MB/s over 7 refs), and the apt install of
  `flatpak` + `flatpak-builder` takes 77 s. The whole toolchain job is ~2m15s. The cost that
  justified excluding `main` does not exist, so the exclusion is currently unjustified rather than
  justified-and-accepted. Left as-is pending a decision, because the argument for including `main` is
  the same one that already keeps the `.deb` build there — packaging breakage found at merge time
  rather than while cutting a release.

## 4. Fix the desktop entry at source, not in the manifest

Inspecting the real `.deb` turned up two defects that are **not** Flatpak's fault and should not be
patched downstream:

* `Categories=` is **empty**. A desktop entry with no categories sorts nowhere in an application
  menu, and Flathub's linter rejects it.
* There is no `Comment=`. Menus and stores show the name with no one-line description.

Both are in the `.deb` we already ship. Patching them inside the Flatpak manifest would fix the
Flatpak and leave the `.deb` wrong, and would put a second definition of the app's metadata in a
second file — the drift this repository has been bitten by three times in one branch.

**Done ahead of the Flatpak work**, in `src-tauri/tauri.conf.json`, the single place both formats read
from:

```json
"category": "SimulationGame",
"shortDescription": "City infrastructure simulator"
```

The mapping was traced through the bundler rather than assumed from the field names:
`bundle.category` → `AppCategory` → `freedesktop_categories()`, where
`SimulationGame => "Game;Simulation;"` (`tauri-bundler/src/bundle/category.rs:171`), landing in the
`{{categories}}` slot of Tauri's shipped `main.desktop` template. `Comment=` is filled from
`short_description()` and the line is **omitted entirely** when that is empty
(`freedesktop/mod.rs:171-174`) — which is why the old entry had no `Comment=` at all rather than a
blank one.

`SimulationGame` rather than plain `Game`: it yields `Game;Simulation;`, so the app still lands in the
Games menu while carrying an accurate subcategory, and it gives macOS
`public.app-category.simulation-games` from the same field.

`scripts/verify-deb.sh` now asserts both, so this cannot silently regress. The assertion was verified
in both directions before landing: **red** against the real pre-fix `.deb` (`::error::the desktop
entry declares no Categories`), **green** against the same package with the two keys patched in. Note
what it tests — `Categories=` with nothing after it is exactly what an unset `bundle.category`
produces, so an assertion checking only that the *key exists* would have passed on the very package
that motivated it.

The Flatpak manifest therefore only *renames* what the `.deb` provides. It never rewrites content,
apart from the `Icon=` key, which must equal the app ID and which the `.deb` cannot know.

### The `.deb`'s own filename

Tauri builds it from `product_name()` with no override (`debian.rs:60`), so it arrives as
`Armchair Metropolist_<version>_amd64.deb` — a space that becomes `%20` in every download URL. There
is no Tauri setting for it: changing `productName` would also rename the macOS `.app` *and* its Dock
label, because `CFBundleDisplayName` comes from the same field (`macos/app.rs:58`, `:220`), and
`bundle.macOS.bundleName` only overrides `CFBundleName`, the menu-bar name.

So the release job renames the **asset** at attach time to
`armchair-metropolist_<version>_amd64.deb`, taking the version from the tag, which `check` has
already proven equals every declared version. Contents untouched; the package's own `Package:` field
was already `armchair-metropolist`.

The `.desktop` filename *inside* the package keeps its space. It is spec-legal, users never see it,
and the Flatpak renames it to the app ID regardless. It is worth knowing about only because it has
already broken one parser: `verify-deb.sh` used `awk '{print $NF}'`, which truncated
`usr/share/applications/Armchair Metropolist.desktop` to `Metropolist.desktop`.

## 5. What the manifest does

`packaging/flatpak/io.github.adsouza.armchair-metropolist.yml`, consuming the built `.deb` as a
`type: file` source:

```yaml
app-id: io.github.adsouza.armchair-metropolist
runtime: org.gnome.Platform
runtime-version: '50'
sdk: org.gnome.Sdk
command: armchair_metropolist
```

The single module unpacks the `.deb` (`ar x`, then `tar -xf data.tar.*` — the compression is not
guaranteed to be gzip and the command must not assume it), copies both binaries into `/app/bin`, and
renames three things so Flatpak can find them:

| From the `.deb` | To, in `/app` |
|---|---|
| `usr/bin/armchair_metropolist`, `usr/bin/desktop` | `/app/bin/` unchanged |
| `usr/share/applications/Armchair Metropolist.desktop` | `/app/share/applications/io.github.adsouza.armchair-metropolist.desktop` |
| `usr/share/icons/hicolor/<size>/apps/armchair_metropolist.png` | `…/apps/io.github.adsouza.armchair-metropolist.png` |
| — | `/app/share/metainfo/io.github.adsouza.armchair-metropolist.metainfo.xml` (new, tracked) |

The renamed desktop file also needs its `Icon=` key pointed at the new icon name. That is the one
content edit the manifest makes, and it is unavoidable: the key must equal the app ID, which the
`.deb` cannot know.

`256x256@2` is a scale-suffixed hicolor directory. It is valid, but is the kind of thing tooling
handles inconsistently; if `flatpak-builder` or `appstream-util` objects, dropping that one size is
acceptable and the two remaining sizes satisfy both.

## 6. Permissions: no network at all

```yaml
finish-args:
  - --socket=wayland
  - --socket=fallback-x11
  - --share=ipc
  - --device=dri
```

**Deliberately no `--share=network`.** Without it Flatpak gives the app a private network namespace,
which still contains loopback. The sidecar binds `127.0.0.1` and the Tauri webview connects to it, so
everything the app does works while it cannot reach the network at all — a strictly better posture
than the `.deb`, which has whatever access the user has.

This is a claim, not a fact, until §7 executes it. If it turns out the webview needs more, the fix is
`--share=network` and a line here recording why; it must not be added pre-emptively "to be safe",
because an unnecessary permission is exactly what a sandbox exists to refuse.

## 7. Verification

By mutation, per the standing rule. `scripts/verify-flatpak.sh` is a sibling to `verify-deb.sh` and
follows its rules: one definition a laptop and a runner both run, and every assertion shown to fail.

**The decisive check is that it runs the application.** §11's own warning is that a glibc mismatch
leaves `flatpak-builder` exiting 0, because all it did was copy files — so every file-existence
assertion in the world cannot see the failure this design most needs to exclude. The script therefore
installs the bundle and, **inside the sandbox**, runs the Burrito sidecar in the foreground under a
`timeout` and asserts that Phoenix's boot banner — `Running … Endpoint` — appears in its output.

**An earlier draft of this section said "curls `127.0.0.1:$PORT`, asserts a 200, and kills it", and
that design hung two CI jobs before being abandoned.** Both hangs came from managing a background
process across a sandbox boundary: first `wait $PID` on a BEAM that does not exit promptly on
SIGTERM, then `kill -9 "$PID"` killing Burrito's *launcher* rather than the `beam.smp` it had
spawned. `flatpak run` does not return while anything lives in the sandbox, and a bare `timeout`
sends SIGTERM and then waits — so with nothing escalating, the job simply stopped.

Reading the banner is as decisive for the failure this assertion targets, and much harder to get
wrong. It needs no HTTP client inside the runtime, no PID tracking and no teardown: `timeout` inside
the sandbox stops the sidecar and the sandbox shell exits on its own. `Running … Endpoint` is printed
only after the loader has resolved every symbol, the bundled ERTS has started, the Burrito payload
has unpacked and the port has been bound — none of which happens on a glibc mismatch.

The one thing it no longer proves directly is that a request gets a response. Binding the port is a
strictly weaker claim than serving a 200, and this section should not pretend otherwise.

That one check exercises, in a single pass: the dynamic loader against the runtime's glibc, the
bundled ERTS, the Burrito payload unpack, Phoenix booting, and §6's claim that loopback works with no
network permission. It needs no display and never opens the Tauri window, which is what makes it
cheap enough to be worth having.

This is also precisely what bundle design §12 called "the honest next increment" and put out of
scope:

> A headless smoke test — install, launch under xvfb, assert the sidecar's port opens — is the honest
> next increment and is out of scope here.

— minus the xvfb, which turns out to be unnecessary once the sidecar rather than the window is the
thing being launched.

| # | Assertion | Mutation that must turn it red |
|---|---|---|
| 1 | a `.flatpak` exists at the expected path | point the glob at a bogus name |
| 2 | its app ID is `io.github.adsouza.armchair-metropolist` | assert an ID that is not there |
| 3 | it requires `org.gnome.Platform/x86_64/50` | change the *assertion* to expect `//49`; it must go red against a `//50` bundle |
| 4 | `/app/share/applications/<app-id>.desktop` exists | skip the rename step in the manifest |
| 5 | the desktop entry's `Icon=` equals the app ID | skip the `Icon=` rewrite |
| 6 | `Categories=` is non-empty | revert §4's `tauri.conf.json` change |
| 7 | **the sidecar boots Phoenix inside the sandbox** | rebuild the whole bundle against `//46` and run this script against *that*; it must fail |

Mutation 7 is the one that matters, and it is different in kind from the others: it does not edit the
script, it rebuilds the artifact against the runtime §11 proposed. Two things have to be true for it
to count, and they are easy to conflate:

* `flatpak-builder` against `//46` must still **exit 0** — if the build itself fails, the mutation
  proved that `//46` is unbuildable, not that our check catches a bad runtime.
* `verify-flatpak.sh` must then go **red at the run step**, with a loader error mentioning `GLIBC_`.

If the build errors instead, the mutation is inconclusive and must be reported as such rather than
scored as a pass. Assuming it, this doubles as a regression test for a design error that was one
merge away from shipping.

Two traps recorded from the last sweep, both hit on 2026-08-03:

* **Do not restore a mutation with `git checkout -- <file>` while the change under test is
  uncommitted.** It reverts to the index, deletes the implementation, and every later mutation then
  tests `HEAD` while printing exactly the red you expected. Commit first.
* **Confirm each mutation actually applied.** A pattern that silently fails to match yields a green
  run that reads as a passing assertion.

## 8. Where it runs — a separate job, not inline in `release`

An earlier draft of this section put the build inline in the `release` job. **That is not
implementable**, and the reason is worth recording rather than quietly working around.

`release` runs only on a tag that has already passed the version guard. So the only way to exercise a
Flatpak step living inside it would be to push a tag matching `mix.exs` exactly — that is, to cut a
real, public Release at the real version. A throwaway `v0.0.1-test` tag fails the guard in `check`,
`release` never starts, and nothing is learned. Developing a 1.5–2 GB, sandbox-dependent build with
no loop short of "publish and see" is not a plan.

`on:` therefore gains **`workflow_dispatch`**, with `BUNDLE` extended to cover it. That buys a real
loop — run the workflow by hand from any branch, get built and verified bundles as artifacts, publish
nothing. Verified on run 30904363993: `release` requires `github.ref_type == 'tag'` and `deploy`
requires `github.event_name == 'push'`, so a dispatch satisfies neither and both were skipped.

**And the build lives in the `desktop` job, not a job of its own.** A separate job was tried first and
is wrong here for a specific reason. It would have to consume the `.deb` as an **artifact** — but
pushes to `main` deliberately do not upload one, since that absence is what closes the route to
installing two same-version packages from CI (releases design §7). Building on `main` would therefore
have meant reopening a hole that was closed on purpose, purely to move a file between two jobs on the
same commit.

Building inside `desktop`, where `mix ex_tauri.build` has just written the `.deb` to disk, needs no
artifact at all. So the Flatpak can be built and verified on **every merge** — which the 50-second
measurement above makes affordable — without touching that property. The steps are gated on the
existing `BUNDLE`, so they run exactly where the `.deb` does: x86_64, on `main`, tags and manual runs,
never on a pull request and never on aarch64.

`release` keeps `needs: [check, desktop]` and gains the `.flatpak` in its asset list. The ordering
property is unchanged: a Flatpak that fails to build or verify fails the `desktop` job, `release`
never starts, and there is no Release at all rather than one missing an asset.

**Measured 2026-08-04**, not estimated: apt install 77 s, runtime + SDK install **50 s**
(`real 0m50.415s`, peaking at 32.2 MB/s), whole job ~2m15s before any build step exists. An earlier
draft of this section guessed "6–12 minutes, dominated by the runtime pull" — wrong by roughly an
order of magnitude, and wrong in the direction that made a design decision look justified. GitHub's
network is the reason: 1.5–2 GB at 32 MB/s is well under a minute.

Nothing waits on it — releases are rare and `deploy` is on a different trigger entirely. A manual run
publishes nothing and deploys nothing: `release` requires `github.ref_type == 'tag'` and `deploy`
requires `github.event_name == 'push'`, both verified skipped on run 30904363993.

## 9. Documentation

* **`README.md`** — the "Installing a release" section gains the Flatpak line, and must say plainly
  that it is side-loaded rather than from Flathub, so nobody expects auto-updates.
* **Bundle design §11** — deferred no longer. Point it here, and correct its `//46` proposal in place
  rather than deleting it, since the reasoning around it is still the best statement of why the glibc
  floor matters.
* **`docs/superpowers/2026-07-30-follow-ups.md`** — the standing record.
* **Bundle design §12** — its "headless smoke test … out of scope here" line is now done, for the
  Flatpak. It remains undone for the `.deb`, and saying which is which keeps the entry honest.

## 10. Known limitations, accepted

* **Side-loaded, not Flathub.** §11's objection stands. This is a prerequisite, not a distribution
  channel.
* **x86_64 only**, for the same reason the `.deb` is.
* **The runtime pull is uncacheable** against the repository's cache budget, and is paid per release.
* **`org.gnome.Platform//50` will go EOL** roughly a year after March 2026. Nothing warns us; the
  runtime version is a tracked string in one manifest and bumping it is a one-line change, but it
  needs to be somebody's job. Recorded here rather than pretended away.
* **The sandbox is unproven against the real window.** §7 launches the sidecar, not the Tauri
  webview, so `--socket=wayland`, `--device=dri` and the tray are reasoned about rather than
  exercised. Launching the window would need xvfb and a much slower check; the glibc class of failure
  is covered, the display-integration class is not.
