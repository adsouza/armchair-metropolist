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
printf 'run:     starting %s inside the sandbox on port %s...\n' "$SIDECAR" "$PORT"

# `timeout` is a hard backstop around the whole sandbox run, independent of the inner
# script's own bounds. It exists because the first version of this check hung a CI job:
# every bound was inside the sandbox, so when the sandbox itself would not exit there
# was nothing left to stop it. A verification step that can hang forever is worse than
# no verification step — it burns a runner and reports nothing.
#
# 180s: the inner probe loop allows 90s, plus BEAM start-up, plus the escalating kill.
TIMEOUT_BIN=$(command -v timeout || true)
[ -n "$TIMEOUT_BIN" ] || fail "coreutils 'timeout' not found; refusing to run unbounded"

# shellcheck disable=SC2016
# The single quotes are the point: $SIDECAR, $PORT and $PID must expand in the
# *sandbox's* shell, where --env has defined them, not in this one. Expanding them out
# here would bake in host values and break $PID entirely.
OUT=$("$TIMEOUT_BIN" 180 flatpak run --user \
        --env=ARMCHAIR_DESKTOP=1 \
        --env=PORT="$PORT" \
        --env=SECRET_KEY_BASE=0000000000000000000000000000000000000000000000000000000000000000 \
        --env=SIDECAR="$SIDECAR" \
        --command=sh "$APP_ID" -c '
          if [ ! -x "$SIDECAR" ]; then echo "SIDECAR_MISSING:$SIDECAR"; exit 0; fi
          "$SIDECAR" --no-halt &
          PID=$!
          # Report which instrument was used. A check that silently degrades to a
          # weaker test while still printing success is the failure mode this whole
          # script exists to avoid.
          if command -v curl >/dev/null 2>&1; then echo "PROBE:curl"
          elif command -v wget >/dev/null 2>&1; then echo "PROBE:wget"
          else echo "PROBE:liveness-only"; fi
          i=0
          while [ $i -lt 90 ]; do
            if command -v curl >/dev/null 2>&1; then
              curl -fsS -o /dev/null "http://127.0.0.1:$PORT/" && { echo SIDECAR_SERVED; break; }
            elif command -v wget >/dev/null 2>&1; then
              wget -q -O /dev/null "http://127.0.0.1:$PORT/" && { echo SIDECAR_SERVED; break; }
            elif [ $i -ge 20 ]; then
              # No HTTP client in the runtime. Falling back to "did not die", which
              # still catches the loader failure this assertion is aimed at, but
              # proves strictly less. Named in the output so nobody reads it as more.
              kill -0 $PID 2>/dev/null && { echo SIDECAR_ALIVE; break; }
            fi
            kill -0 $PID 2>/dev/null || { echo SIDECAR_DIED; break; }
            i=$((i+1)); sleep 1
          done
          # Teardown must be bounded. An earlier version ended with `wait $PID`, which
          # hung a CI job indefinitely: the BEAM does not exit promptly on SIGTERM here
          # (ShutdownManager has its own drain), `flatpak run` does not return until its
          # child tree is gone, and `wait` has no timeout. Escalate instead, and never
          # block on the child.
          kill "$PID" 2>/dev/null || true
          for _ in 1 2 3 4 5; do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
          kill -9 "$PID" 2>/dev/null || true
        ' 2>&1) && RC=0 || RC=$?

printf '%s\n' "$OUT" | sed -n 's/^PROBE:/probe:   /p'

# 124 is `timeout`'s signal that it fired. Distinguished from every other failure
# because it means something did not terminate, which is a different bug from the app
# not working — and reporting it as "the sidecar never served" would send the next
# person looking in the wrong place.
if [ "$RC" -eq 124 ]; then
  printf '%s\n' "$OUT" >&2
  fail "the sandbox run did not finish within 180s — something did not exit, see above"
fi

case "$OUT" in
  *SIDECAR_SERVED*)
    printf 'run:     served HTTP on 127.0.0.1:%s inside the sandbox\n' "$PORT" ;;
  *SIDECAR_ALIVE*)
    printf 'run:     stayed alive 20s inside the sandbox (no HTTP client in the runtime)\n' ;;
  *SIDECAR_MISSING*)
    printf '%s\n' "$OUT" >&2
    fail "$SIDECAR is not in the sandbox — the manifest did not install it" ;;
  *GLIBC_*)
    printf '%s\n' "$OUT" >&2
    fail "the app died at the dynamic loader: the runtime's glibc is too old for this binary" ;;
  *)
    printf '%s\n' "$OUT" >&2
    fail "the sidecar neither served nor survived inside the sandbox" ;;
esac

printf '\n\033[32m✓ .flatpak verified\033[0m\n'
