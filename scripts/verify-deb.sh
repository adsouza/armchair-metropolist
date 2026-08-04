#!/bin/sh
# Every assertion about the .deb that `mix ex_tauri.build --bundles deb` produces.
#
# A script rather than inline workflow steps, because §12 of
# docs/superpowers/specs/2026-08-02-linux-desktop-bundle-design.md requires each
# assertion be *shown to fail*, and doing that inline would mean four pushes to main —
# four ~10-minute runs and four production deploys. Mutating this file against a
# downloaded artifact costs nothing. It also follows the same rule as `mix check` and
# src-tauri/.cargo/audit.toml: one definition a laptop and a runner both run.
#
#   Usage: scripts/verify-deb.sh [bundle-dir]
#   macOS: brew install dpkg   (CI needs nothing; Ubuntu ships dpkg-deb)

set -eu

BUNDLE_DIR="${1:-src-tauri/target/release/bundle}"

fail() {
  # ::error:: is a GitHub annotation; harmless noise in a terminal.
  printf '::error::%s\n' "$1" >&2
  exit 1
}

command -v dpkg-deb >/dev/null 2>&1 \
  || fail "dpkg-deb not found (macOS: brew install dpkg)"

# 1. A .deb exists. On failure, print the tree — the first run on Linux is the only
#    thing that establishes where Tauri actually puts it.
DEB=$(find "$BUNDLE_DIR/deb" -type f -name '*.deb' 2>/dev/null | head -1)
if [ -z "$DEB" ]; then
  ls -R "$BUNDLE_DIR" 2>/dev/null || echo "($BUNDLE_DIR does not exist)"
  fail "no .deb under $BUNDLE_DIR/deb"
fi
printf 'bundle:  %s (%s)\n' "$DEB" "$(du -h "$DEB" | cut -f1)"

# 2. Nothing else was built. A stray appimage/ or rpm/ means --bundles deb was ignored,
#    which would silently reintroduce AppImage's five build-time downloads — two of them
#    from an unpinned master branch.
for unwanted in appimage rpm; do
  [ ! -d "$BUNDLE_DIR/$unwanted" ] \
    || fail "--bundles deb did not take: $BUNDLE_DIR/$unwanted exists"
done

# 3. The package declares its runtime dependencies. Tauri writes no Depends: field
#    unless tauri.conf.json supplies one (debian.rs:204), and a .deb declaring nothing
#    installs onto a machine with no WebKit and then dies at the dynamic linker. This is
#    the standing regression test for that.
# A bare VAR=$(cmd) propagates cmd's exit status under set -e, which would abort here
# without the ::error:: annotation if dpkg-deb itself errored (as opposed to succeeding
# with an empty field, which the next line already handles).
DEPENDS=$(dpkg-deb --field "$DEB" Depends) || fail "dpkg-deb --field failed reading $DEB"
[ -n "$DEPENDS" ] || fail "the .deb declares no Depends"
printf 'Depends: %s\n' "$DEPENDS"

# 4. The Burrito sidecar is inside. A bundle without it is an empty window. Tauri strips
#    the target triple from externalBin entries — on macOS the file lands as
#    Contents/MacOS/desktop — so the *name* is asserted and the directory is not, because
#    the Linux path is not yet known.
# Fields 6..NF, not $NF: `dpkg-deb --contents` puts the path last but paths here contain
# spaces — this package really ships `usr/share/applications/Armchair Metropolist.desktop`,
# which $NF truncates to `Metropolist.desktop`. That truncation cannot produce a false
# negative, but `.../Armchair desktop` would truncate to exactly `desktop` and pass
# vacuously, which is the failure this assertion exists to prevent.
if ! dpkg-deb --contents "$DEB" | awk '{ out=$6; for (i=7;i<=NF;i++) out = out " " $i; print out }' | grep -qE '(^|/)desktop$'; then
  dpkg-deb --contents "$DEB"
  fail "the Burrito sidecar (a file named 'desktop') is not inside the .deb"
fi

# 5. The desktop entry is usable. Tauri writes `Categories=` from `bundle.category` and
#    omits `Comment=` entirely when `bundle.shortDescription` is empty
#    (freedesktop/mod.rs:167-174), and for a long time this package shipped an empty
#    `Categories=` and no comment at all: an entry that sorts nowhere in an application
#    menu and describes itself to nobody. Flathub's linter rejects the former outright,
#    so this is also a precondition for the Flatpak.
#
#    Extracted with `dpkg-deb -x` into a temp dir rather than piped through
#    `tar --wildcards`, which BSD tar on macOS does not support — and this script has to
#    run identically on a laptop and a runner.
WORK=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '$WORK'" EXIT INT TERM
dpkg-deb -x "$DEB" "$WORK" || fail "dpkg-deb -x failed reading $DEB"

DESKTOP=$(find "$WORK/usr/share/applications" -type f -name '*.desktop' 2>/dev/null | head -1)
[ -n "$DESKTOP" ] || fail "no .desktop entry in the .deb"

# `Categories=` with nothing after it is what an unset bundle.category produces, so the
# emptiness *is* the bug — testing only for the key's presence would pass on the very
# package this assertion was written against.
CATEGORIES=$(sed -n 's/^Categories=//p' "$DESKTOP")
[ -n "$CATEGORIES" ] \
  || fail "the desktop entry declares no Categories (set bundle.category in tauri.conf.json)"
case "$CATEGORIES" in
  *Game*) ;;
  *) fail "Categories=$CATEGORIES does not place this in Game" ;;
esac

COMMENT=$(sed -n 's/^Comment=//p' "$DESKTOP")
[ -n "$COMMENT" ] \
  || fail "the desktop entry has no Comment (set bundle.shortDescription in tauri.conf.json)"

printf 'Desktop: %s\n' "$(basename "$DESKTOP")"
printf '  Categories=%s\n  Comment=%s\n' "$CATEGORIES" "$COMMENT"

# 6. Observed rather than asserted: proves at runtime that tauri.conf.json is the version
#    authority and src-tauri/Cargo.toml is the fallback Tauri never takes.
printf 'Version: %s\n' "$(dpkg-deb --field "$DEB" Version)"

printf '\n\033[32m✓ .deb verified\033[0m\n'
