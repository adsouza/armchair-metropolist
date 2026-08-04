# Flatpak Bundle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a `.flatpak` from the release `.deb` and attach it to every GitHub Release, with a check that proves the app actually runs inside the sandbox.

**Architecture:** A `flatpak-builder` manifest repackages the already-built `.deb` against `org.gnome.Platform//50`. It runs in its own CI job — reachable by `workflow_dispatch` as well as by a tag — so the build has a development loop that does not require publishing. `release` gains `needs: [flatpak]` and attaches the artifact.

**Tech Stack:** flatpak 1.x + flatpak-builder, `org.gnome.Platform`/`org.gnome.Sdk` 50, AppStream metainfo, GitHub Actions, POSIX sh.

**Spec:** `docs/superpowers/specs/2026-08-04-flatpak-bundle-design.md`. Read §2 and §7 before Task 1.

## Global Constraints

- **Runtime is `org.gnome.Platform//50` with `org.gnome.Sdk//50`.** GNOME 48+ clears our `libc6 (>= 2.39)` floor; `//46` does not and is Task 5's deliberate failure case.
- **App ID is `io.github.adsouza.armchair-metropolist`**, identical to the Tauri `identifier`. Valid because its only dash is in the last component.
- **Nothing here is testable on macOS.** Every task ends with a CI run. Use `gh workflow run` — never a tag — until Task 5.
- **Do not push a `v*` tag at any point in this plan.** `v0.1.0` is reserved as the first real release. A tag that disagrees with `mix.exs` fails `check`; a tag that agrees cuts a public Release.
- **`--share=network` must NOT be added.** A private netns still has loopback, which is all the app needs. If something appears to require it, that is a finding to report, not a line to add.
- **Verification is by mutation.** Every assertion must be shown to fail. `scripts/verify-flatpak.sh` follows `scripts/verify-deb.sh`: POSIX `sh`, a `fail()` that prints `::error::`, runnable against a downloaded artifact.
- **Terminology:** "allowlist" / "denylist" only.
- **Commit style:** imperative subject, body explaining *why*, ending with `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.
- **Already done, do not redo:** `bundle.category`/`bundle.shortDescription` in `tauri.conf.json` and their `verify-deb.sh` assertions (`4032703`); Release asset renaming (`59fd3d3`).

---

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `.github/workflows/ci.yml` | Modify — `on:` (~line 3), `BUNDLE` (line 153), new `flatpak` job after `release` (~line 424), `release.needs` (line 333) and its `gh release create` (~line 401) | Triggers, the build job, attaching the asset |
| `packaging/flatpak/io.github.adsouza.armchair-metropolist.yml` | Create | The flatpak-builder manifest. Repackages the `.deb`; owns permissions |
| `packaging/flatpak/io.github.adsouza.armchair-metropolist.metainfo.xml` | Create | AppStream metadata. Required by Flathub, warned about by builder tooling |
| `scripts/verify-flatpak.sh` | Create | Every assertion about the built bundle, including the decisive run-it check |
| `README.md`, spec §9's list | Modify | Install instructions and the standing record |

**Why a separate job rather than steps inside `release`:** see spec §8. `release` only runs on a tag that passes the version guard, so an inline step could only ever be exercised by cutting a real public Release.

---

## Task 1: A Flatpak job that installs the toolchain and proves nothing else

The point of this task is a working loop and a measurement. It deliberately builds nothing.

**Files:**
- Modify: `.github/workflows/ci.yml` — `on:` block (~line 3), `BUNDLE` (line 153), new job after the `release` job

**Interfaces:**
- Consumes: artifact `desktop-bundle-x86_64-unknown-linux-gnu` produced by the `desktop` job.
- Produces: a job named `flatpak` that later tasks add steps to; `workflow_dispatch` as a trigger.

- [ ] **Step 1: Add `workflow_dispatch` to the triggers**

In `.github/workflows/ci.yml`, after the `pull_request:` line (~line 18):

```yaml
  # Manual runs exist for the flatpak job below, which is otherwise reachable only
  # from a v* tag — and a tag that matches mix.exs cuts a real public Release, so
  # "push a tag and see" is not a development loop. A dispatch run builds and
  # verifies the bundle and publishes nothing. It stays useful afterwards: it is how
  # you check the Flatpak still builds after a runtime bump without cutting a release.
  workflow_dispatch:
```

- [ ] **Step 2: Extend `BUNDLE` so a dispatch run produces a .deb to repackage**

Replace line 153:

```yaml
      BUNDLE: ${{ (github.event_name == 'workflow_dispatch' || (github.event_name == 'push' && (github.ref == 'refs/heads/main' || github.ref_type == 'tag'))) && matrix.target == 'x86_64-unknown-linux-gnu' }}
```

- [ ] **Step 3: Make the .deb artifact available to dispatch runs too**

The upload step is currently `if: env.BUNDLE == 'true' && github.ref_type == 'tag'`. The `flatpak` job downloads that artifact, so a dispatch run needs it:

```yaml
        if: env.BUNDLE == 'true' && (github.ref_type == 'tag' || github.event_name == 'workflow_dispatch')
```

Pushes to `main` still do not upload it — that property is from the releases design and must not regress.

- [ ] **Step 4: Add the job**

After the `release` job, before `rust-advisory`:

```yaml
  # Repackages the .deb into a Flatpak. Its own job rather than steps inside
  # `release` because `release` only runs on a tag that passed the version guard —
  # so an inline step could only ever be exercised by publishing. See
  # docs/superpowers/specs/2026-08-04-flatpak-bundle-design.md §8.
  flatpak:
    name: flatpak bundle
    runs-on: ubuntu-24.04
    needs: [desktop]
    if: github.ref_type == 'tag' || github.event_name == 'workflow_dispatch'

    steps:
      - uses: actions/checkout@v7

      - uses: actions/download-artifact@v8
        with:
          name: desktop-bundle-x86_64-unknown-linux-gnu
          path: deb

      # None of these are on GitHub's ubuntu-24.04 image — checked against the
      # runner-images readme with controls in both directions. `flatpak` pulls
      # bubblewrap and ostree in as dependencies.
      - name: Install the Flatpak toolchain
        run: |
          sudo apt-get update
          sudo apt-get install -y flatpak flatpak-builder

      # --user throughout: no sudo, and the runtime lands somewhere the build can
      # read without privilege. The runtime is ~1.5-2 GB and is deliberately not
      # cached — the repository cache budget is already holding four mix caches.
      - name: Install the GNOME runtime and SDK
        run: |
          flatpak remote-add --user --if-not-exists \
            flathub https://dl.flathub.org/repo/flathub.flatpakrepo
          time flatpak install --user -y flathub org.gnome.Platform//50 org.gnome.Sdk//50
          flatpak list --user --runtime

      # Task 1 ends here on purpose: this run establishes that the toolchain
      # installs, that user namespaces work on this runner, and what the runtime
      # pull actually costs. Building anything before knowing that conflates two
      # failures.
      - name: Report what we have to work with
        run: |
          flatpak --version
          flatpak-builder --version
          ls -la deb/
```

- [ ] **Step 5: Lint**

```bash
actionlint .github/workflows/ci.yml && echo clean
```

- [ ] **Step 6: Commit and push the branch**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: add a flatpak job that installs the toolchain

Its own job rather than steps inside release, because release only runs on a
tag that passed the version guard — so an inline step could only be exercised
by cutting a real public Release, which is not a development loop.

workflow_dispatch makes the job reachable from any branch, and BUNDLE is
extended to cover dispatch runs so a .deb exists to repackage. Pushes to main
still do not upload a .deb.

This job builds nothing yet: this run is to establish that the toolchain
installs, that user namespaces work on the runner, and what the runtime pull
costs, before anything depends on all three.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
git push -u origin flatpak-bundle
```

- [ ] **Step 7: Run it and read the measurement**

```bash
gh workflow run CI --ref flatpak-bundle
sleep 30 && gh run list --branch flatpak-bundle --limit 1
```

Then watch the `flatpak bundle` job. **Record three things in the next commit message:** how long `flatpak install` took, the versions of `flatpak` and `flatpak-builder`, and the `.deb` filename as it arrives.

**Stop and report if:** the install fails, or `flatpak install` errors about user namespaces / bubblewrap permissions. That is a hosted-runner constraint, not something to work around by adding `sudo` — report it.

---

## Task 2: The manifest and the AppStream metadata

**Files:**
- Create: `packaging/flatpak/io.github.adsouza.armchair-metropolist.metainfo.xml`
- Create: `packaging/flatpak/io.github.adsouza.armchair-metropolist.yml`
- Modify: `.github/workflows/ci.yml` — the `flatpak` job

**Interfaces:**
- Consumes: Task 1's `flatpak` job and its `deb/` download path.
- Produces: `armchair-metropolist.flatpak` in the job's working directory, and an artifact named `flatpak-bundle`.

- [ ] **Step 1: Write the AppStream metainfo**

Create `packaging/flatpak/io.github.adsouza.armchair-metropolist.metainfo.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <id>io.github.adsouza.armchair-metropolist</id>
  <metadata_license>CC0-1.0</metadata_license>
  <project_license>AGPL-3.0-only</project_license>

  <name>Armchair Metropolist</name>
  <summary>City infrastructure simulator</summary>

  <description>
    <p>
      Zone land, lay transit, and watch a city grow or stall. Armchair Metropolist
      simulates the interaction between housing, jobs, money and labour: every block
      you place changes what the surrounding blocks can support.
    </p>
  </description>

  <launchable type="desktop-id">io.github.adsouza.armchair-metropolist.desktop</launchable>
  <url type="homepage">https://github.com/adsouza/armchair-metropolist</url>
  <url type="bugtracker">https://github.com/adsouza/armchair-metropolist/issues</url>

  <content_rating type="oars-1.1" />

  <releases>
    <release version="0.1.0" date="2026-08-04" />
  </releases>
</component>
```

**On `project_license`, which is not a formality.** This field is displayed by software
centres and is a licence declaration inside a distributable package, so a wrong value is
a wrong legal claim. `LICENSE` in this repository is the **GNU Affero General Public
License v3** — an earlier draft of this very plan guessed `MIT`, which is how this note
came to exist.

`AGPL-3.0-only` rather than `-or-later` is the conservative reading of a bare `LICENSE`
file with no per-file "or any later version" notice anywhere in the tree. If the
intention is or-later, it is a one-word change here — but make it deliberately rather
than by copying whichever value appears first in a search.

- [ ] **Step 2: Write the manifest**

Create `packaging/flatpak/io.github.adsouza.armchair-metropolist.yml`:

```yaml
# Repackages the .deb that `mix ex_tauri.build --bundles deb` produces. Flatpak is
# not a Tauri bundle target — PackageType in tauri-bundler enumerates deb, rpm,
# appimage, dmg, app, msi, ios and updater, and nothing else — so this manifest is
# the whole integration.
app-id: io.github.adsouza.armchair-metropolist
runtime: org.gnome.Platform
runtime-version: '50'
sdk: org.gnome.Sdk
command: armchair_metropolist

# No --share=network, deliberately. Without it Flatpak gives the app a *private*
# network namespace, which still contains loopback — and loopback is all it needs:
# the Burrito sidecar binds 127.0.0.1 and the webview connects to it. So the app
# works while being unable to reach the network at all, which is strictly better
# than the .deb. verify-flatpak.sh proves this rather than assuming it; if it ever
# fails, the fix is a line here plus the reason, never a pre-emptive permission.
finish-args:
  - --socket=wayland
  - --socket=fallback-x11
  - --share=ipc
  - --device=dri

modules:
  - name: armchair-metropolist
    buildsystem: simple
    build-commands:
      # `ar x` then the data tarball. The compression is NOT assumed to be gzip:
      # dpkg has shipped .gz, .xz and .zst over the years and `tar -xf` sniffs it.
      - ar x *.deb
      - tar -xf data.tar.*

      - install -Dm755 usr/bin/armchair_metropolist /app/bin/armchair_metropolist
      - install -Dm755 usr/bin/desktop /app/bin/desktop

      # Flatpak requires the desktop entry and icons to be named for the app ID.
      # The .deb names them from productName and mainBinaryName respectively, so
      # both are renamed here. The `Icon=` rewrite is the only *content* edit this
      # manifest makes, and it is unavoidable: the key must equal the app ID, which
      # the .deb has no way to know.
      - install -Dm644 "usr/share/applications/Armchair Metropolist.desktop"
          /app/share/applications/io.github.adsouza.armchair-metropolist.desktop
      - sed -i 's/^Icon=.*/Icon=io.github.adsouza.armchair-metropolist/'
          /app/share/applications/io.github.adsouza.armchair-metropolist.desktop

      - install -Dm644 usr/share/icons/hicolor/128x128/apps/armchair_metropolist.png
          /app/share/icons/hicolor/128x128/apps/io.github.adsouza.armchair-metropolist.png
      - install -Dm644 usr/share/icons/hicolor/32x32/apps/armchair_metropolist.png
          /app/share/icons/hicolor/32x32/apps/io.github.adsouza.armchair-metropolist.png

      - install -Dm644 io.github.adsouza.armchair-metropolist.metainfo.xml
          /app/share/metainfo/io.github.adsouza.armchair-metropolist.metainfo.xml
    sources:
      - type: file
        path: app.deb
      - type: file
        path: io.github.adsouza.armchair-metropolist.metainfo.xml
```

The `256x256@2` icon from the `.deb` is deliberately not installed: it is a
scale-suffixed hicolor directory that tooling handles inconsistently, and the two
plain sizes satisfy both Flatpak and AppStream.

- [ ] **Step 3: Add the build steps to the job**

Replace Task 1's "Report what we have to work with" step with:

```yaml
      # The manifest names its source `app.deb` rather than globbing, because the
      # real filename contains a space (`Armchair Metropolist_0.1.0_amd64.deb` —
      # Tauri builds it from productName) and a flatpak-builder `path:` is not a
      # glob. Staging it under a fixed name is simpler than quoting through YAML,
      # sh and the builder.
      - name: Stage the sources
        run: |
          set -eu
          DEB=$(find deb -name '*.deb' -type f | head -1)
          test -n "$DEB" || { echo "::error::no .deb in the artifact"; find deb -type f; exit 1; }
          cp "$DEB" packaging/flatpak/app.deb
          ls -la packaging/flatpak/

      - name: Build the Flatpak
        run: |
          set -eu
          flatpak-builder --user --disable-rofiles-fuse --force-clean \
            --repo=repo build-dir \
            packaging/flatpak/io.github.adsouza.armchair-metropolist.yml
          flatpak build-bundle repo armchair-metropolist.flatpak \
            io.github.adsouza.armchair-metropolist
          ls -la armchair-metropolist.flatpak

      - uses: actions/upload-artifact@v7
        with:
          name: flatpak-bundle
          path: armchair-metropolist.flatpak
          if-no-files-found: error
          retention-days: 14
```

`--disable-rofiles-fuse` because FUSE is not available in a hosted runner; without
it `flatpak-builder` fails setting up its copy-on-write build directory.

- [ ] **Step 4: Lint and commit**

```bash
actionlint .github/workflows/ci.yml && echo clean
git add packaging/flatpak .github/workflows/ci.yml
git commit -m "feat: build a Flatpak from the release .deb

A flatpak-builder manifest repackaging the .deb against org.gnome.Platform//50,
since Flatpak is not a Tauri bundle target and never will be from our side.

The manifest only renames what the .deb provides — the desktop entry and icons
must be named for the app ID — apart from the Icon= key, which has to equal the
app ID and which the .deb cannot know.

No --share=network: a private network namespace still has loopback, which is
all the sidecar and webview need, so the app works while being unable to reach
the network at all.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
git push
```

- [ ] **Step 5: Run it**

```bash
gh workflow run CI --ref flatpak-bundle
```

Expected: a `flatpak-bundle` artifact appears. **Download and keep it** — Task 3
mutates its verification script against this exact file, which is what makes those
mutations free.

```bash
gh run download <run-id> -n flatpak-bundle -D /tmp/fp
```

**Stop and report if** `flatpak-builder` fails on the `install -Dm644` line for the
spaced desktop path. The fix is quoting inside the manifest's build-commands, and
the exact quoting that works is worth recording in the commit body.

---

## Task 3: `scripts/verify-flatpak.sh`

**Files:**
- Create: `scripts/verify-flatpak.sh`
- Modify: `.github/workflows/ci.yml` — one step in the `flatpak` job

**Interfaces:**
- Consumes: `armchair-metropolist.flatpak` from Task 2.
- Produces: `scripts/verify-flatpak.sh [bundle-path]`, exit 0 on success, non-zero with an `::error::` line otherwise.

- [ ] **Step 1: Write the script**

Create `scripts/verify-flatpak.sh`:

```sh
#!/bin/sh
# Every assertion about the .flatpak that packaging/flatpak/*.yml produces.
#
# A script rather than inline workflow steps, for the same reason verify-deb.sh is
# one: §7 of the design requires each assertion be *shown to fail*, and doing that
# inline would mean a CI round trip per mutation.
#
#   Usage: scripts/verify-flatpak.sh [bundle-path]
#   Needs: flatpak. Linux only — the run check installs and executes the app.

set -eu

BUNDLE="${1:-armchair-metropolist.flatpak}"
APP_ID=io.github.adsouza.armchair-metropolist
EXPECTED_RUNTIME=org.gnome.Platform/x86_64/50

fail() {
  printf '::error::%s\n' "$1" >&2
  exit 1
}

command -v flatpak >/dev/null 2>&1 || fail "flatpak not found (Linux only)"

# 1. The bundle exists.
[ -f "$BUNDLE" ] || fail "no bundle at $BUNDLE"
printf 'bundle:  %s (%s)\n' "$BUNDLE" "$(du -h "$BUNDLE" | cut -f1)"

# 2 & 3. It declares the app ID and runtime we think it does. `flatpak info --show-*`
#        reads the bundle's own metadata rather than trusting the filename.
GOT_ID=$(flatpak info --show-ref "$BUNDLE" 2>/dev/null | cut -d/ -f2) \
  || fail "flatpak could not read $BUNDLE"
[ "$GOT_ID" = "$APP_ID" ] || fail "app id is '$GOT_ID', expected '$APP_ID'"

GOT_RUNTIME=$(flatpak info --show-runtime "$BUNDLE" 2>/dev/null)
[ "$GOT_RUNTIME" = "$EXPECTED_RUNTIME" ] \
  || fail "runtime is '$GOT_RUNTIME', expected '$EXPECTED_RUNTIME'"
printf 'app:     %s on %s\n' "$GOT_ID" "$GOT_RUNTIME"

# Install it. --user needs no privilege; the app is removed at the end.
flatpak install --user -y --bundle "$BUNDLE" >/dev/null 2>&1 \
  || fail "could not install $BUNDLE"
# shellcheck disable=SC2064
trap "flatpak uninstall --user -y '$APP_ID' >/dev/null 2>&1 || true" EXIT INT TERM

# 4 & 5. The desktop entry is named for the app ID and points at the right icon.
#        Flatpak exports entries by app ID; an entry under any other name is not
#        picked up by a desktop environment at all.
DESKTOP="$HOME/.local/share/flatpak/exports/share/applications/$APP_ID.desktop"
[ -f "$DESKTOP" ] || fail "no exported desktop entry at $DESKTOP"

ICON=$(sed -n 's/^Icon=//p' "$DESKTOP")
[ "$ICON" = "$APP_ID" ] || fail "desktop entry has Icon=$ICON, expected $APP_ID"

# 6. Categories survived the repackaging. This is the .deb-side fix (bundle.category
#    in tauri.conf.json) observed at the far end of the pipeline: `Categories=` with
#    nothing after it is what an unset category produces, so emptiness is the bug and
#    testing for the key's presence would pass on a broken package.
CATEGORIES=$(sed -n 's/^Categories=//p' "$DESKTOP")
[ -n "$CATEGORIES" ] || fail "the exported desktop entry declares no Categories"
case "$CATEGORIES" in *Game*) ;; *) fail "Categories=$CATEGORIES is not in Game" ;; esac
printf 'desktop: Categories=%s Icon=%s\n' "$CATEGORIES" "$ICON"

# 7. THE decisive assertion. Everything above reads files, and a glibc mismatch is
#    invisible to every one of them: flatpak-builder exits 0 having only copied,
#    and the failure happens at process start. So actually start the sidecar inside
#    the sandbox and talk to it.
#
#    This exercises, in one pass: the dynamic loader against the runtime's glibc,
#    the bundled ERTS, the Burrito payload unpack, Phoenix booting, and the claim
#    in the manifest that loopback works with no --share=network. It needs no
#    display because it never opens the Tauri window.
#
#    --no-halt is REQUIRED: Burrito launches the release as
#    `erl -noshell -s elixir start_cli`, which treats trailing arguments as scripts
#    and then halts, so without it the sidecar boots Phoenix and exits 0.
#    ARMCHAIR_DESKTOP=1 selects the file-backed store; without it this binary is the
#    server target and waits on a Postgres that is not there.
PORT=41000
printf 'run:     starting the sidecar inside the sandbox...\n'
OUT=$(flatpak run --user \
        --env=ARMCHAIR_DESKTOP=1 \
        --env=PORT="$PORT" \
        --env=SECRET_KEY_BASE=0000000000000000000000000000000000000000000000000000000000000000 \
        --command=sh "$APP_ID" -c '
          /app/bin/desktop --no-halt &
          PID=$!
          i=0
          while [ $i -lt 60 ]; do
            if command -v curl >/dev/null 2>&1; then
              curl -fsS -o /dev/null "http://127.0.0.1:'"$PORT"'/" && { echo SIDECAR_OK; break; }
            else
              (echo > /dev/tcp/127.0.0.1/'"$PORT"') 2>/dev/null && { echo SIDECAR_OK; break; }
            fi
            kill -0 $PID 2>/dev/null || { echo SIDECAR_DIED; break; }
            i=$((i+1)); sleep 1
          done
          kill $PID 2>/dev/null || true
        ' 2>&1) || true

case "$OUT" in
  *SIDECAR_OK*)
    printf 'run:     the sidecar served HTTP on 127.0.0.1:%s inside the sandbox\n' "$PORT" ;;
  *GLIBC_*|*"version `GLIBC"*)
    printf '%s\n' "$OUT" >&2
    fail "the app died at the dynamic loader — the runtime's glibc is too old" ;;
  *)
    printf '%s\n' "$OUT" >&2
    fail "the sidecar never served HTTP inside the sandbox" ;;
esac

printf '\n\033[32m✓ .flatpak verified\033[0m\n'
```

- [ ] **Step 2: Check it is syntactically valid and lint-clean**

```bash
sh -n scripts/verify-flatpak.sh && echo "sh -n clean"
chmod +x scripts/verify-flatpak.sh
shellcheck scripts/verify-flatpak.sh || true    # advisory; verify-deb.sh is clean, match it
```

Fix anything shellcheck reports, since `verify-deb.sh` passes cleanly and these are siblings.

- [ ] **Step 3: Wire it into the job**

After the "Build the Flatpak" step:

```yaml
      - name: Verify the Flatpak
        run: ./scripts/verify-flatpak.sh armchair-metropolist.flatpak
```

- [ ] **Step 4: Commit and run**

```bash
git add scripts/verify-flatpak.sh .github/workflows/ci.yml
git commit -m "test: verify the Flatpak by running it, not by listing its files

A glibc mismatch leaves flatpak-builder exiting 0 — all it did was copy files —
so every file-existence assertion is blind to the failure this design most
needs to exclude. The decisive check therefore starts the Burrito sidecar
inside the sandbox and curls it.

That exercises the dynamic loader against the runtime's glibc, the bundled
ERTS, the payload unpack, Phoenix booting, and the manifest's claim that
loopback works with no --share=network, in one pass and with no display.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
git push
gh workflow run CI --ref flatpak-bundle
```

Expected: the job goes green and the log shows `the sidecar served HTTP on
127.0.0.1:41000 inside the sandbox`.

**If it reports `the sidecar never served HTTP`:** read the captured output before
changing anything. The three likely causes are distinguishable and want different
fixes — a missing `--no-halt` (process exits 0 immediately), a missing runtime
library (loader error naming a `.so`), or the sidecar needing longer than 60s
(Burrito unpacks its payload on first run). Do **not** add `--share=network`
speculatively; if the app genuinely needs it, the failure will not be an HTTP
timeout on loopback.

- [ ] **Step 5: Mutate assertions 1-6 against the downloaded bundle**

These are free — run them on the artifact from Task 2 Step 5, on a Linux box or the
runner, never by pushing. **Commit first** so a restore cannot eat the work: a
`git checkout --` restore over uncommitted changes deletes the implementation and
leaves later mutations testing `HEAD` while printing exactly the red you expected.

For each, edit `scripts/verify-flatpak.sh`, run it against the good bundle, confirm
red, then restore from a copy:

| Mutation | Expected |
|---|---|
| `APP_ID=io.github.adsouza.wrong` | red: "app id is …, expected …" |
| `EXPECTED_RUNTIME=org.gnome.Platform/x86_64/46` | red: "runtime is …/50, expected …/46" |
| `DESKTOP=…/nosuchentry.desktop` | red: "no exported desktop entry" |
| compare `ICON` against `"wrong"` | red: "desktop entry has Icon=…" |
| `case "$CATEGORIES" in *Zzz*)` | red: "Categories=… is not in Game" |

Then confirm the unmutated script still passes. **Check each mutation actually
applied** (`cmp` against the backup) — a pattern that silently fails to match yields
a green run that reads as a passing assertion.

- [ ] **Step 6: Commit the mutation evidence**

```bash
git commit --allow-empty -m "test: record the verify-flatpak mutation sweep

Assertions 1-6 each shown to fail individually against the real bundle, and the
unmutated script still green afterwards. Assertion 7 — the run check — is
mutated separately in the next task, because falsifying it means rebuilding the
whole bundle against a different runtime.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 4: Attach it to the Release, and correct the docs

**Files:**
- Modify: `.github/workflows/ci.yml` — `release.needs` (line 333) and its download/create steps
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-08-02-linux-desktop-bundle-design.md` §11, §12
- Modify: `docs/superpowers/2026-07-30-follow-ups.md`

**Interfaces:**
- Consumes: artifact `flatpak-bundle` from Task 2.
- Produces: a `.flatpak` asset on each Release.

- [ ] **Step 1: Make `release` wait for the Flatpak**

Line 333 becomes:

```yaml
    needs: [check, desktop, flatpak]
```

This is the ordering property: a Flatpak that fails to build or verify means
`release` never starts, so there is no Release at all rather than one missing an
asset.

- [ ] **Step 2: Include it in the asset check and the upload**

In the "Verify every asset arrived" step, after the sidecar loop:

```bash
          FLATPAK="artifacts/flatpak-bundle/armchair-metropolist.flatpak"
          test -f "$FLATPAK" \
            || { echo "::error::missing flatpak bundle"; find artifacts -type f; exit 1; }
          FLATPAK_OUT="artifacts/armchair-metropolist_${VERSION}_x86_64.flatpak"
          mv "$FLATPAK" "$FLATPAK_OUT"
          echo "FLATPAK=$FLATPAK_OUT" >> "$GITHUB_ENV"
```

and add `"$FLATPAK" \` to the `gh release create` argument list.

- [ ] **Step 3: Lint**

```bash
actionlint .github/workflows/ci.yml && echo clean
```

- [ ] **Step 4: README**

In the "Installing a release" section, after the `.deb` instructions:

````markdown
Or, on any distribution with Flatpak:

```bash
flatpak install --user ./armchair-metropolist_<version>_x86_64.flatpak
flatpak run io.github.adsouza.armchair-metropolist
```

This is the one to take if your distribution's glibc is older than Ubuntu 24.04's
2.39 — the `.deb` inherits the build machine's, the Flatpak does not. It is
side-loaded rather than from Flathub, so it will not auto-update; `flatpak install`
the next release over it.

It runs with no network access at all. A Flatpak without `--share=network` still
has loopback, which is all the app uses.
````

- [ ] **Step 5: Correct bundle design §11 and §12**

§11 is headed "Flatpak, deferred" and is no longer. Add at its top:

```markdown
**Built, 2026-08-04** — see `2026-08-04-flatpak-bundle-design.md`. The analysis below
stands and is worth reading, with one correction already noted inline: the
`org.gnome.Platform//46` it proposes was never viable against a `libc6 (>= 2.39)`
floor. What shipped targets `//50` and attaches a `.flatpak` to each Release. The
channel objection also stands — it is side-loaded, not on Flathub.
```

In §12, the "Two things this cannot verify" list ends with a bullet saying a headless
smoke test is "the honest next increment and is out of scope here". Append:

```markdown
  **Done for the Flatpak, 2026-08-04**, and without xvfb: `scripts/verify-flatpak.sh`
  starts the *sidecar* rather than the window, so no display is needed. Still undone
  for the `.deb`, which is still only checked by inspecting its contents.
```

- [ ] **Step 6: Follow-ups doc**

Add to the resolved section:

```markdown
* **Flatpak bundle — done 2026-08-04.** Each Release now carries a `.flatpak` built
  by repackaging the `.deb` against `org.gnome.Platform//50`, verified by running the
  sidecar inside the sandbox. Reachable by `workflow_dispatch` for testing without
  publishing. Not on Flathub — side-loaded, so no auto-updates. Spec:
  `specs/2026-08-04-flatpak-bundle-design.md`.
```

- [ ] **Step 7: Commit**

```bash
git add .github/workflows/ci.yml README.md docs/
git commit -m "feat: attach the Flatpak to each Release

release now needs the flatpak job, so a bundle that fails to build or verify
means no Release at all rather than one missing an asset.

Corrects the bundle design's §11, which deferred this, and §12, whose 'headless
smoke test is the honest next increment' is now done for the Flatpak — without
xvfb, since starting the sidecar rather than the window needs no display. Still
undone for the .deb.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
git push
gh workflow run CI --ref flatpak-bundle
```

Expected: green, with a `flatpak-bundle` artifact. `release` stays skipped — this is
not a tag.

---

## Task 5: Prove the run check can fail

Assertions 1-6 were mutated in Task 3. Assertion 7 — the one the whole design rests
on — has only ever been observed passing, which is exactly the state this repository
treats as unverified.

**Files:** none committed. This task is an experiment whose result goes in a commit
message and the spec.

- [ ] **Step 1: Temporarily target the runtime that should fail**

On a scratch commit, change **two** places to `46`: `runtime-version: '50'` in the
manifest, and `EXPECTED_RUNTIME=…/50` in the script — otherwise assertion 3 fires
first and you learn nothing about assertion 7. Also change the runtime install step
to `org.gnome.Platform//46 org.gnome.Sdk//46`.

```bash
gh workflow run CI --ref flatpak-bundle
```

- [ ] **Step 2: Read the result against the two outcomes that count**

* **`flatpak-builder` exits 0 and `verify-flatpak.sh` fails at the run step**, with a
  loader error mentioning `GLIBC_`. This is the result that validates the design: the
  build could not see the problem and the run check could.
* **`flatpak-builder` itself fails**, or GNOME 46 is no longer on Flathub at all
  (it is EOL, and Flathub does eventually remove EOL runtimes). Then the mutation is
  **inconclusive** — it proved `//46` is unusable, not that the check catches a bad
  runtime. Report it as inconclusive. Do not score it as a pass.

- [ ] **Step 3: Revert the scratch commit and record what happened**

```bash
git revert --no-edit HEAD    # or reset if unpushed
```

Add the outcome to spec §7 under mutation 7, in one of two forms — "confirmed: build
exited 0, run check failed with `<the actual error>`" or "inconclusive: `//46` could
not be built/installed, so the run check remains unfalsified". Then commit:

```bash
git add docs/superpowers/specs/2026-08-04-flatpak-bundle-design.md
git commit -m "docs: record the outcome of the //46 mutation

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
git push
```

- [ ] **Step 4: Final gate**

```bash
mix check && actionlint .github/workflows/ci.yml && sh -n scripts/verify-flatpak.sh
```

All three clean. Then hand off via `superpowers:finishing-a-development-branch`.

---

## Self-Review

**Spec coverage.** §2's measured facts are constraints, not tasks. §3 scope → the job's
`if:` in Task 1. §4 already shipped in `4032703`/`59fd3d3`, and Task 3's assertion 6
observes it at the far end of the pipeline. §5 manifest → Task 2. §6 permissions →
Task 2 Step 2, proved by Task 3's assertion 7. §7 verification → Task 3 Steps 1/5 and
Task 5. §8 job placement → Task 1. §9 docs → Task 4 Steps 4-6. §10's limitations are
accepted, not implemented.

**Type consistency.** `armchair-metropolist.flatpak` is the filename produced in Task 2
Step 3 and consumed in Task 3 Step 3 and Task 4 Step 2. Artifact name `flatpak-bundle`
matches across Task 2 Step 3 and Task 4 Step 2. `APP_ID`, `EXPECTED_RUNTIME` and
`$DESKTOP` are defined once in Task 3 Step 1 and mutated by those names in Step 5.
`packaging/flatpak/app.deb` is written in Task 2 Step 3 and named as `path: app.deb`
in Task 2 Step 2.

**Two things a fresh implementer will hit that are not defects in this plan.** The
manifest's multi-line `build-commands` entries use YAML line continuation by
indentation; if `flatpak-builder` mis-parses them, put each command on one line — the
content is what matters, not the wrapping. And `flatpak info --show-ref` output format
should be confirmed on the first real run before assertion 2's `cut -d/ -f2` is trusted;
if it differs, fix the parse rather than weakening the assertion to a `grep`.

**Known gap.** Nothing here proves the Tauri *window* runs — `--socket=wayland`,
`--device=dri` and the tray are reasoned about, never exercised, because that needs
xvfb and a much slower check. Spec §10 records this. The glibc class of failure is
covered; the display-integration class is not, and the first person to run the Flatpak
on a real desktop is the test.
