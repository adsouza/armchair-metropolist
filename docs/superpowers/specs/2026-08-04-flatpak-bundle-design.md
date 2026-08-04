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
* **Building on pushes to `main`.** The runtime pull is 1.5–2 GB and uncacheable against a repository
  budget already holding four mix caches. At release cadence that is affordable; per merge it is not.

## 4. Fix the desktop entry at source, not in the manifest

Inspecting the real `.deb` turned up two defects that are **not** Flatpak's fault and should not be
patched downstream:

* `Categories=` is **empty**. A desktop entry with no categories sorts nowhere in an application
  menu, and Flathub's linter rejects it.
* There is no `Comment=`. Menus and stores show the name with no one-line description.

Both are in the `.deb` we already ship. Patching them inside the Flatpak manifest would fix the
Flatpak and leave the `.deb` wrong, and would put a second definition of the app's metadata in a
second file — the drift this repository has been bitten by three times in one branch.

So they are fixed in `src-tauri/tauri.conf.json` instead, which is the single place both formats read
from. Tauri exposes `bundle.category` and `bundle.shortDescription`; **whether those map onto the
Linux `Categories=` and `Comment=` keys must be verified by rebuilding the `.deb` and re-reading the
entry**, not assumed from the field names. If they do not map, the fallback is
`bundle.linux.deb.desktopTemplate`, a tracked template file — still one definition, still upstream of
both formats.

The Flatpak manifest then only *renames* what the `.deb` provides. It never rewrites content.

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
installs the bundle and, **inside the sandbox**, sets `PORT`, starts the Burrito sidecar, curls
`127.0.0.1:$PORT`, asserts a 200, and kills it.

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
| 7 | **the sidecar serves HTTP inside the sandbox** | rebuild the whole bundle against `//46` and run this script against *that*; it must fail |

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

## 8. Effect on the release job

Added between the existing asset check and `gh release create`: an apt install, a
`flatpak remote-add --if-not-exists flathub`, a runtime + SDK install, `flatpak-builder`, then
`scripts/verify-flatpak.sh`.

Estimated 6–12 minutes on top of the release job, dominated by the 1.5–2 GB runtime pull. Nothing
waits on it: releases are rare, and `deploy` is on a different trigger entirely.

A failure here fails the job **before** `gh release create` runs, so a broken Flatpak yields no
Release rather than a Release missing an asset — the same ordering the asset check already
establishes.

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
