#!/bin/sh
# Cut a tag-driven GitHub release from a clean, up-to-date main checkout.
#
# Usage: scripts/release.sh X.Y.Z

set -eu

fail() {
  printf '\n\033[31m\342\234\227 release: %s\033[0m\n' "$1" >&2
  exit 1
}

[ "$#" -eq 1 ] || fail "usage: scripts/release.sh X.Y.Z"

VERSION=$1
printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || fail "version must be MAJOR.MINOR.PATCH (for example, 0.4.0)"

TAG="v$VERSION"
SCRIPT_DIR=$(
  CDPATH=''
  cd "$(dirname "$0")"
  pwd
)
ROOT=$(git -C "$SCRIPT_DIR/.." rev-parse --show-toplevel 2>/dev/null) \
  || fail "scripts/release.sh is not inside a Git checkout"
cd "$ROOT"

command -v mix >/dev/null 2>&1 || fail "mix is not installed or not on PATH"

BRANCH=$(git branch --show-current)
[ "$BRANCH" = "main" ] || fail "releases must be cut from main (currently on $BRANCH)"

[ -z "$(git status --porcelain)" ] \
  || fail "the worktree is not clean; commit or stash the current changes first"

git remote get-url origin >/dev/null 2>&1 || fail "Git remote 'origin' is not configured"

printf 'Fetching origin/main...\n'
git fetch --quiet origin main || fail "could not fetch origin/main"

BEHIND=$(git rev-list --count HEAD..origin/main)
[ "$BEHIND" -eq 0 ] \
  || fail "main is behind origin/main by $BEHIND commit(s); pull before releasing"

if git rev-parse --quiet --verify "refs/tags/$TAG" >/dev/null; then
  fail "local tag $TAG already exists"
fi

if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
  fail "tag $TAG already exists on origin"
else
  REMOTE_TAG_STATUS=$?
  [ "$REMOTE_TAG_STATUS" -eq 2 ] || fail "could not check whether $TAG exists on origin"
fi

printf '\nBumping the project to %s...\n' "$VERSION"
mix version.set "$VERSION"

printf '\nRunning the local quality gate...\n'
mix precommit

VERSION_FILES='mix.exs
packaging/flatpak/io.github.adsouza.armchair-metropolist.metainfo.xml
src-tauri/Cargo.lock
src-tauri/Cargo.toml
src-tauri/tauri.conf.json'

CHANGED_FILES=$(git diff --no-ext-diff --name-only | LC_ALL=C sort)
[ "$CHANGED_FILES" = "$VERSION_FILES" ] || {
  printf '\nExpected only these version files to change:\n%s\n' "$VERSION_FILES" >&2
  printf '\nActually changed:\n%s\n' "${CHANGED_FILES:-  (none)}" >&2
  fail "unexpected release diff; inspect it before committing"
}

printf '\nCreating release commit and annotated tag %s...\n' "$TAG"
# shellcheck disable=SC2086
git add $VERSION_FILES
git commit -m "Release $VERSION"
git tag -m "Armchair Metropolist $VERSION" "$TAG"

printf '\nPushing main and %s atomically...\n' "$TAG"
git push --atomic origin "HEAD:refs/heads/main" "refs/tags/$TAG"

printf '\n\033[32m\342\234\223 %s pushed; GitHub Actions is building the release\033[0m\n' "$TAG"
printf '  https://github.com/adsouza/armchair-metropolist/actions\n'
