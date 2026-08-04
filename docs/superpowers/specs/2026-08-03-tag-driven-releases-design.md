# Tag-driven GitHub Releases — design

## 1. Problem

The `.deb` pipeline works and publishes a package on every push to `main`, but the packages it produces
are not safely installable by anyone, and they expire.

Two facts from the bundle design (`2026-08-02-linux-desktop-bundle-design.md`, §10) combine into a
real bug:

* `version` in `mix.exs` has been `"0.1.0"` since the project began.
* A production Burrito binary unpacks its payload **once**, keyed on nothing but
  `<name>_erts-<erts>_<app version>`. `evict_burrito_payload_cache/1` clears only the *build* machine.

So two different `0.1.0` packages installed in sequence give the second one a stale payload: new code
that never runs. This already cost a day of debugging once on the desktop target. Right now it is
reachable by anyone who downloads two consecutive `main` artifacts.

Separately, CI artifacts expire after 14 days and require repository access to download, so there is
no durable, public thing to point a person at.

The fix §10 nominated, and this design builds: make the version meaningful by making a git tag the
trigger, and publish to a permanent GitHub Release.

## 2. Decisions taken

Recorded because each closes off a plausible alternative, and the reasons are not recoverable from the
diff.

| Decision | Chosen | Rejected, and why |
|---|---|---|
| Source of truth | `mix.exs`; the tag is a **claim that gets checked** | Tag-as-truth, rewriting files in CI — a checkout would no longer know its own version and `check_versions/1` would lose its meaning |
| Release contents | x86_64 `.deb` + Burrito sidecars for **both** arches | Both-arch `.deb`: aarch64 has no prebuilt `cargo-tauri`, so it needs a ~5 min `cargo install` plus a full 338-crate compile on a slower runner, for an audience of nobody so far |
| `main` pushes | Keep building **and verifying** the `.deb`; stop uploading it | Bundling only on tags — packaging breakage would then surface while cutting a release, the worst moment. Keeping the upload — fully redundant with the Release |
| Workflow layout | Extend `ci.yml` | A separate `release.yml` — it would need its own copy of the `desktop` job, and hand-maintained mirrors in this repository have drifted three times in one branch |
| Version bumping | A `mix version.set` task | Documenting four manual edits, one of which is a regenerated `Cargo.lock` |

## 3. Trigger, and where the tag's shape is checked

```yaml
on:
  push:
    branches: [main]
    tags: ['v*']
  pull_request:
```

**`v*`, not a semver glob.** GitHub's workflow-syntax page states that filter patterns accept glob
characters including `*`, `**`, `+`, `?` and `!`, but the cheat sheet defining whether `+` means "one
or more", whether character classes like `[0-9]` are supported, and whether `.` stays literal could
not be retrieved during this design. A trigger that silently never fires is
the worst failure available here, so the glob stays coarse and deliberately over-matches, and the
precise check happens in Elixir where it is unit-testable (§4).

The repository already carries a non-version tag, `backup-pre-squash`, which `v*` excludes. A future
`v`-prefixed non-release tag would trigger the workflow and then fail the §4 guard — a loud, explained
failure, which is the correct outcome for a tag that looks like a release and is not.

**Existing jobs need no change to stay correct on tags:**

* `deploy` carries `if: github.event_name == 'push' && github.ref == 'refs/heads/main'`. A tag ref is
  not `refs/heads/main`, so a tag never deploys. Verified by reading the condition, not assumed.
* `check` and `rust advisory` will run on tags. That is wanted: nothing should be released that fails
  the suite, and §5 makes the release job depend on `check`.

## 4. The fifth site: conditional, and fatal when malformed

`check_versions/1` compares four sites today. It runs first in the `check` alias because it costs
milliseconds, and `check` is both the PR gate and the pre-push hook — **neither has a release tag in
scope.** An unconditional fifth site would therefore read `nil` on every laptop and every pull
request, and the existing nil-guard is deliberately fatal, so it would fail all of them.

The tag becomes a site only when the release job exports it:

```elixir
sites =
  [
    {"mix.exs", Mix.Project.config()[:version]},
    {"src-tauri/tauri.conf.json", tauri_conf_version()},
    {"src-tauri/Cargo.toml", cargo_toml_version()},
    {"src-tauri/Cargo.lock", cargo_lock_version()}
  ] ++ release_tag_site()
```

`release_tag_site/0` distinguishes three cases, and the distinction between the second and third is
the whole point of the function:

| `RELEASE_TAG` | Returns | Effect |
|---|---|---|
| unset, or `""` | `[]` | four sites — today's behaviour exactly, laptops and PRs unaffected |
| `v0.2.0` | `[{"git tag v0.2.0", "0.2.0"}]` | compared with the rest; disagreement is fatal |
| `v0.2`, `refs/tags/v1.2.3`, `vfoo` | `[{"git tag <raw>", nil}]` | **nil-guard fires** |

Returning `[]` for a *malformed* tag would skip the check in silence — precisely the "a version check
that silently reads nothing passes forever" failure the nil-guard exists to prevent. Set-but-
unparseable must be fatal, not absent.

**The empty string is the exception, and it is not a nicety.** GitHub Actions cannot conditionally
omit an environment variable: a job-level `RELEASE_TAG: ${{ github.ref_type == 'tag' &&
github.ref_name || '' }}` evaluates to `""` on every branch push. Treating `""` as malformed would
therefore make the nil-guard fatal on every push to `main` and every pull request — the guard would
fire constantly and be disabled within a day. `""` is how "no tag" arrives from CI, so it means
absent. A human never types it; the shapes a human gets wrong (`v0.2`, a full `refs/tags/…` ref) all
still trip the guard.

This is why the check can live at job level in `check` rather than needing a separate step: one line
of YAML, no extra `mix` invocation, and `check` already runs on tags (§3).

The strip is `"v" <> rest` where `rest` matches `~r/\A\d+\.\d+\.\d+\z/`. Anchored with `\A`/`\z`
rather than `^`/`$`, because `$` accepts a trailing newline and `refs/tags/v1.2.3\n` is exactly the
kind of value a workflow hands over.

### Two neighbours this falsifies

Both are in the function being edited, and both are the kind of thing an edit leaves stale:

1. The mismatch message says **"All four must carry the same value."** With five sites that sentence
   is false. It becomes count-derived, or is reworded to name no number.
2. The same message's remediation names only the `Cargo.toml` → `Cargo.lock` path. With `mix
   version.set` existing (§6) it should point there instead.

## 5. Job wiring

Three edits to `desktop`, one new job.

**`BUNDLE`** currently means "push to main, and x86_64". It becomes "(push to main **or** a `v*` tag),
and x86_64". The `.deb` is built and `scripts/verify-deb.sh` runs in both cases, so packaging
breakage is still caught at merge time.

**The `.deb` artifact upload** becomes tag-only. On `main` the package is built, verified, and
discarded; the Release is the durable copy. This also closes the second route to the §1 bug: nobody
can install two same-version `.deb`s from `main` artifacts, because there are none.

**Sidecar uploads stay unconditional**, as today — both arches, and the release job consumes them.

**New `release` job:**

```yaml
release:
  needs: [check, desktop]
  if: startsWith(github.ref, 'refs/tags/v')
```

`needs: [check]` is load-bearing: without it a tag whose tests fail still publishes. `needs:
[desktop]` waits for both matrix legs, so a broken aarch64 sidecar blocks the Release rather than
producing a partial one.

It downloads the three artifacts and calls `gh release create` with `--generate-notes`. GitHub
composes the body from commits since the previous tag; the squash-merge convention means every line is
already a readable PR title, so this needs no maintenance. A missing asset makes `gh release create`
exit non-zero rather than publishing an incomplete set.

## 6. `mix version.set`

Four sites must move together and one of them is a lock file that must be regenerated rather than
edited. The correct incantation is not the obvious one: `cargo metadata --offline` exits 101; the form
that works is `cargo update --offline -p armchair_metropolist`.

`mix version.set 0.2.0` therefore:

1. Validates the argument against `~r/\A\d+\.\d+\.\d+\z/` and raises otherwise.
2. Rewrites `version:` in `mix.exs`, `"version"` in `src-tauri/tauri.conf.json`, and `version` in the
   `[package]` table of `src-tauri/Cargo.toml`.
3. Shells out to `cargo update --offline -p armchair_metropolist` to move the lock.
4. Re-runs the `check_versions/1` comparison and reports the agreed value.

Step 4 is what makes the task trustworthy: it does not claim success, it re-derives it using the same
reader that guards the build. `check_versions/1` already *catches* drift; this *prevents* it.

Release procedure, end to end:

```bash
mix version.set 0.2.0
git commit -am "Release 0.2.0" && git push
git tag v0.2.0 && git push origin v0.2.0
```

## 7. What this fixes, and what it does not

**Fixed, for released `.deb`s.** Tags are unique, so distinct releases carry distinct versions, so
distinct Burrito cache keys. Forgetting to bump before tagging is a red build (§4) rather than a broken
install. And `main` no longer publishing `.deb`s closes the route by which two same-version *packages*
could be obtained from CI.

**Still open, and worth being exact about, because the obvious summary is wrong.** "No same-version
artifact is obtainable from CI any more" would be false. The Burrito **sidecar** *is* the binary whose
payload cache causes this, and §5 keeps sidecar uploads unconditional on every push to `main`. So
downloading two `desktop_x86_64-unknown-linux-gnu` artifacts from consecutive merges still yields a
second one whose payload does not refresh.

Accepted rather than fixed, for a stated reason: those artifacts exist for us to debug an unreleased
merge, they are not what anyone is pointed at to install, and gating them behind tags would remove the
only way to test a merge before releasing it. Anyone using them that way needs
`evict_burrito_payload_cache/1`, which already runs as the last step of the `desktop` release
(`mix.exs`, `releases:` → `desktop` → `steps:`) and so covers the build machine but not a second
machine the binary is copied to. Documentation, not machinery — but it must say this, not the tidier
false version.

A developer rebuilding `0.1.0` locally hits the same thing for the same reason.

**Not addressed.** Release signing, `SHA256SUMS`, Flathub, and macOS/Windows artifacts. GitHub serves
assets over HTTPS; a digest file nobody verifies is ceremony. Revisit if the audience changes.

## 8. Documentation this change makes stale

The change is not done until these are corrected, because each is a claim a reader would otherwise
act on.

* **`README.md`** — gains an "Installing a release" section (download the `.deb` from Releases,
  `sudo apt install ./<file>.deb`) and a "Cutting a release" section carrying §6's three commands.
  Its "Running the desktop app" section currently describes only the macOS bundle paths.
* **Bundle design §10** — all of this lives in the section's **last bullet and its indented
  sub-paragraph**, not in three separate bullets; an implementer looking for three will not find them.
  Three claims there need annotating: artifacts expiring after 14 days and needing repository access
  (superseded for releases); `version` being load-bearing "the moment anyone installs this" (now
  guarded); and the assertion that release cadence makes the arm64 `cargo install tauri-cli`
  affordable — we considered it and declined (§2), so the reason belongs on the record rather than
  reading as still-intended. The sub-paragraph also predicts the tag becomes "a fifth site" in the
  §6 check; §4 above keeps that intent but makes the site conditional, and the prediction should be
  corrected rather than left to look like a spec of the implementation.
* **Bundle design §11 (Flatpak)** — deferred again, but two of its statements should be updated rather
  than left to mislead a future reader:
  * It proposes `org.gnome.Platform//46` and flags the runtime's glibc as unverified and "the first
    thing to establish". Partly established now: GNOME 47 moved to freedesktop-sdk 24.08
    (`gnome-build-meta!3447`), and freedesktop-sdk 24.08 ships glibc 2.40. Since the `.deb` declares
    `libc6 (>= 2.39)`, **`//46` was very likely never viable** and `//47`/`//48` clears the floor.
    Recorded as a lead, not a settled fact — it was read from upstream merge requests, not measured
    inside a runtime.
  * Its risk 2, the Burrito payload cache across updates, is resolved for released artifacts by this
    design. It should point here rather than describe an open problem.
* **Bundle design §12** — it requires the alignment check be mutated **one site at a time**, "four
  separate mutations, not one", because a single mutation leaves it unknown whether the other sites
  are read at all. A fifth site makes that sweep five. The count is written out in prose and will
  otherwise silently under-test the new site.
* **`docs/superpowers/2026-07-30-follow-ups.md`** — the standing record; the release work moves from
  intended to done, and the §1 bug moves to resolved-for-releases.

`docs/deploying.md` needs no change: it concerns the Gigalixir web target, which releases do not
touch.

## 9. Verification, by mutation

Per the standing rule in this repository — a check that passes because it is doing nothing looks
identical to one that passes because it is satisfied. Rows 1-6 are free and run on a laptop; only 7-9
need CI.

| # | Mutation | Expected |
|---|---|---|
| 1 | `RELEASE_TAG=v9.9.9 mix check` | fails, listing five sites and the disagreement |
| 2 | `RELEASE_TAG=garbage mix check` | fails via the **nil-guard**, naming the tag site as unreadable |
| 2b | `RELEASE_TAG=refs/tags/v0.1.0 mix check` | fails via the nil-guard — a full ref is not a tag name |
| 3 | `RELEASE_TAG=v0.1.0 mix check` | passes, prints `[versions] 0.1.0` |
| 4 | `mix check` with `RELEASE_TAG` unset | passes with four sites — proves laptops and PRs are unaffected |
| 4b | `RELEASE_TAG= mix check` (empty) | passes with four sites — this is what every main push sends |
| 5 | `mix version.set 0.2.0` then `git diff --stat` | exactly four files changed |
| 6 | `mix version.set 0.2` | raises before touching any file |
| 7 | push tag `v0.0.1` while `mix.exs` says `0.1.0` | release job fails the guard; **no Release created** |
| 8 | push tag `v0.1.0` | Release created carrying one `.deb` and two sidecars |
| 9 | delete a sidecar artifact before the upload step | `gh release create` exits non-zero |

Row 2 is the one that matters most and is easiest to get wrong: it distinguishes "the guard fired" from
"the guard was skipped", and a naive implementation returning `[]` passes row 1 while failing row 2.

**On top of the table, the existing per-site sweep must be re-run at its new width.** Bundle design
§12 requires each version site be mutated *one at a time* — its words are "four separate mutations,
not one" — so that a passing check cannot hide a site nobody reads. With the tag site present that is
**five** mutations, run with `RELEASE_TAG` set so the fifth is live. Re-running the old four-mutation
sweep and calling it done would leave the new site untested by exactly the argument §12 exists to
make.

Rows 7 and 8 need real tag pushes. Row 7's tag must then be deleted. Row 8 is not a throwaway: `0.1.0`
is the current version, so **the first genuine release doubles as the positive test.**
