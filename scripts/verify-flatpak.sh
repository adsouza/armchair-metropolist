#!/bin/sh
# Every assertion about the .flatpak that packaging/flatpak/*.yml produces.
#
# A script rather than inline workflow steps, for the same reason verify-deb.sh is one:
# §7 of docs/superpowers/specs/2026-08-04-flatpak-bundle-design.md requires each
# assertion be *shown to fail*, and this repository has been bitten enough times by
# checks that pass because they are doing nothing.
#
# Unlike verify-deb.sh this cannot run on a laptop — it installs and executes a
# Flatpak, so it is Linux-only. That is why the expectations below are overridable by
# environment variable: it lets the whole mutation sweep run as one step inside a
# single CI run (see "Prove the Flatpak checks can fail" in ci.yml) rather than costing
# one push per mutation. The defaults are what the real invocation uses; nothing sets
# these variables outside the sweep.
#
#   Usage: scripts/verify-flatpak.sh [bundle-path]

set -eu

BUNDLE="${1:-armchair-metropolist.flatpak}"

APP_ID="${EXPECT_APP_ID:-io.github.adsouza.armchair-metropolist}"
EXPECTED_RUNTIME="${EXPECT_RUNTIME:-org.gnome.Platform/x86_64/50}"
# Which binary the run check starts. A mutation hook: pointing it at something that
# does not exist must turn assertion 7 red, which is how we know that assertion is
# wired to anything at all.
SIDECAR="${EXPECT_SIDECAR:-/app/bin/desktop}"
PORT="${EXPECT_PORT:-41000}"

fail() {
  printf '::error::%s\n' "$1" >&2
  exit 1
}

command -v flatpak >/dev/null 2>&1 || fail "flatpak not found (this script is Linux-only)"

# 1. The bundle exists.
[ -f "$BUNDLE" ] || fail "no bundle at $BUNDLE"
printf 'bundle:  %s (%s)\n' "$BUNDLE" "$(du -h "$BUNDLE" | cut -f1)"

# 2. It installs, under the app ID we expect. Installing first and then interrogating
#    the *installed* app avoids depending on how `flatpak info` reads a bundle file,
#    and it is a real assertion in its own right: a malformed bundle fails here.
flatpak install --user -y --bundle "$BUNDLE" >/dev/null 2>&1 \
  || fail "could not install $BUNDLE"
# shellcheck disable=SC2064
trap "flatpak uninstall --user -y '$APP_ID' >/dev/null 2>&1 || true" EXIT INT TERM

flatpak info --user "$APP_ID" >/dev/null 2>&1 \
  || fail "installed, but not as '$APP_ID' — flatpak list --user shows what it is"

# 3. It requires the runtime we think it does. This is the cheap half of the glibc
#    question; assertion 7 is the half that actually settles it.
GOT_RUNTIME=$(flatpak info --user --show-runtime "$APP_ID" 2>/dev/null) \
  || fail "could not read the runtime of $APP_ID"
[ "$GOT_RUNTIME" = "$EXPECTED_RUNTIME" ] \
  || fail "runtime is '$GOT_RUNTIME', expected '$EXPECTED_RUNTIME'"
printf 'app:     %s on %s\n' "$APP_ID" "$GOT_RUNTIME"

# 4. The desktop entry is exported under the app ID. Flatpak exports entries by ID; an
#    entry under any other name is invisible to every desktop environment, which is a
#    silent failure — the app installs and simply never appears in a menu.
DESKTOP="$HOME/.local/share/flatpak/exports/share/applications/$APP_ID.desktop"
[ -f "$DESKTOP" ] || fail "no exported desktop entry at $DESKTOP"

# 5. Its Icon key names the app ID. The .deb ships `Icon=armchair_metropolist`, which
#    resolves to nothing once the icon is renamed for Flatpak, so this is the standing
#    regression test for the manifest's one content edit.
ICON=$(sed -n 's/^Icon=//p' "$DESKTOP")
[ "$ICON" = "$APP_ID" ] || fail "desktop entry has Icon=$ICON, expected $APP_ID"

# 6. Categories survived the repackaging. This observes the tauri.conf.json fix at the
#    far end of the pipeline. `Categories=` with nothing after it is exactly what an
#    unset bundle.category produces, so the emptiness is the bug — an assertion that
#    only checked the key's presence would pass on a broken package.
CATEGORIES=$(sed -n 's/^Categories=//p' "$DESKTOP")
[ -n "$CATEGORIES" ] || fail "the exported desktop entry declares no Categories"
case "$CATEGORIES" in *Game*) ;; *) fail "Categories=$CATEGORIES does not place this in Game" ;; esac
printf 'desktop: Icon=%s Categories=%s\n' "$ICON" "$CATEGORIES"

# 7. THE decisive assertion.
#
# Everything above reads files, and a glibc mismatch is invisible to all of it:
# flatpak-builder exits 0 having only copied, and the failure happens at process start.
# So start the sidecar inside the sandbox and talk to it.
#
# This exercises, in one pass: the dynamic loader against the runtime's glibc, the
# bundled ERTS, the Burrito payload unpack, Phoenix booting, and the manifest's claim
# that loopback works with no --share=network. No display is needed, because this
# starts the *sidecar* rather than the Tauri window.
#
# --no-halt is REQUIRED: Burrito launches the release as `erl -noshell -s elixir
# start_cli`, which treats trailing arguments as scripts and then halts, so without it
# the sidecar boots Phoenix, says so, and exits 0.
# ARMCHAIR_DESKTOP=1 selects the file-backed store; without it this binary is the
# server target and waits on a Postgres that is not there.
# Run it in the FOREGROUND under a self-imposed timeout, and read its output. No
# backgrounding, no PID tracking, no teardown.
#
# Two earlier versions of this check hung a CI job, and both times the cause was
# managing a background process across a sandbox boundary:
#
#   1. `wait $PID` on a BEAM that does not exit promptly on SIGTERM.
#   2. `kill -9 "$PID"` — which killed Burrito's *launcher*, not the `beam.smp` it had
#      spawned. `flatpak run` does not return while anything is alive in the sandbox,
#      so the outer `timeout 180` sent SIGTERM at 180s and then waited forever for a
#      process that was never going to die. `timeout` without --kill-after does not
#      escalate; it blocks.
#
# The fix is to stop trying to manage the process at all. `timeout` *inside* the
# sandbox bounds the sidecar itself and kills its whole tree, and `exec` means the
# sandbox shell is replaced rather than left waiting on a child. The sandbox therefore
# always exits on its own.
#
# Reading the boot banner is as decisive as an HTTP request for what this assertion is
# aimed at, and needs no HTTP client inside the runtime. "Running ... Endpoint" is
# printed only after the loader resolved every symbol, the bundled ERTS started, the
# Burrito payload unpacked and Phoenix bound the port. A glibc mismatch never reaches it.
#
# --no-halt is REQUIRED: Burrito launches the release as `erl -noshell -s elixir
# start_cli`, which treats trailing arguments as scripts and then halts, so without it
# the sidecar boots Phoenix, says so, and exits 0 before we could ask it anything.
# ARMCHAIR_DESKTOP=1 selects the file-backed store; without it this binary is the
# server target and waits on a Postgres that is not there.
printf 'run:     starting %s inside the sandbox on port %s...\n' "$SIDECAR" "$PORT"

TIMEOUT_BIN=$(command -v timeout || true)
[ -n "$TIMEOUT_BIN" ] || fail "coreutils 'timeout' not found; refusing to run unbounded"

# --kill-after on the OUTER timeout too: belt and braces, so that even if the sandbox
# somehow survives its inner bound, SIGKILL follows 15s after SIGTERM rather than this
# script blocking. That omission is exactly what turned bug 2 above into a hung job.
# shellcheck disable=SC2016
# Single quotes deliberate: $SIDECAR and $PORT must expand in the sandbox's shell,
# where --env defined them, not in this one.
OUT=$("$TIMEOUT_BIN" --kill-after=15 120 flatpak run --user \
        --env=ARMCHAIR_DESKTOP=1 \
        --env=PORT="$PORT" \
        --env=SECRET_KEY_BASE=0000000000000000000000000000000000000000000000000000000000000000 \
        --env=SIDECAR="$SIDECAR" \
        --command=sh "$APP_ID" -c '
          [ -x "$SIDECAR" ] || { echo "SIDECAR_MISSING:$SIDECAR"; exit 0; }
          timeout --kill-after=5 45 "$SIDECAR" --no-halt 2>&1 || echo "SIDECAR_EXIT:$?"
          exit 0
        ' 2>&1) && RC=0 || RC=$?

printf '%s\n' "$OUT" | sed 's/^/         | /' | head -25

# The sandbox shell always `exit 0`s, so a non-zero RC here can only come from the
# *outer* timeout — never from the inner one, whose firing is the expected success path
# (the sidecar is a server; it does not stop on its own). Without that separation, 124
# would be ambiguous between "worked, then we stopped it" and "hung".
if [ "$RC" -ne 0 ]; then
  printf '%s\n' "$OUT" >&2
  fail "the sandbox did not exit within 120s (rc=$RC) — something in it would not die"
fi

# Judged on output, not exit status. "Running ... Endpoint" is Phoenix's boot banner and
# it is printed only after the loader resolved every symbol, the bundled ERTS started,
# the Burrito payload unpacked and the port was bound. Nothing reaches it on a glibc
# mismatch, so it is as decisive here as an HTTP request — and needs no HTTP client
# inside the runtime, which is what the previous version could not guarantee.
case "$OUT" in
  *Running*Endpoint*)
    printf 'run:     Phoenix booted and bound a port inside the sandbox\n' ;;
  *SIDECAR_MISSING*)
    printf '%s\n' "$OUT" >&2
    fail "$SIDECAR is not in the sandbox — the manifest did not install it" ;;
  *GLIBC_*)
    printf '%s\n' "$OUT" >&2
    fail "the app died at the dynamic loader: the runtime's glibc is too old for this binary" ;;
  *)
    printf '%s\n' "$OUT" >&2
    fail "the sidecar ran but never printed Phoenix's boot banner — see its output above" ;;
esac

printf '\n\033[32m✓ .flatpak verified\033[0m\n'
