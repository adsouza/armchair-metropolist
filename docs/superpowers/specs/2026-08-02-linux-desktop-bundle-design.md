# A Linux desktop bundle in CI — design

**Date:** 2026-08-02
**Status:** implemented 2026-08-02; CI verification pending (§12)

## 1. Problem

The `desktop` matrix job in `.github/workflows/ci.yml` runs `mix release desktop --overwrite` and
uploads the result. That produces the **Burrito sidecar** — a single-file executable carrying the
Elixir release — and nothing else. It is not a runnable application: it has no window, no webview,
no desktop entry, no icon. The thing a user installs is the Tauri wrapper around it, and the task
that produces one, `mix ex_tauri.build`, has never been called by CI on any platform.

So the pipeline builds half the product. On macOS the other half is built by hand and is recorded
as working (`docs/superpowers/2026-07-30-follow-ups.md`, "The production desktop build"). On Linux
it has never been built at all.

This is a missing pipeline step rather than a missing capability. The Linux GUI target already
exists: on `x86_64-unknown-linux-gnu` the crate resolves gtk 0.18.2, webkit2gtk 2.0.2, gdk, atk and
libappindicator, which is the reason `src-tauri/.cargo/audit.toml` carries the RUSTSEC-2024-0429
glib exception at all.

## 2. Measured starting position

Job timings from run `30771595298` (warm `_build` cache), which is the baseline every figure in §9
is measured against:

| job | total | of which `mix release desktop` |
|---|---|---|
| `desktop · aarch64-unknown-linux-gnu` | 57 s | 34 s |
| `desktop · x86_64-unknown-linux-gnu` | 95 s | 69 s |
| `check · Elixir 1.20.2` | 47 s | — |

That run was a pull request, so `deploy` was skipped. Its figures come from run `30771661681`, the
push to main immediately after: both `check` legs finished by T+50 s, `deploy` started at T+54 s and
finished at T+107 s.

Facts established by reading the tools rather than their documentation:

| question | answer |
|---|---|
| What does `bundle.targets` declare? | **`"all"`** (`src-tauri/tauri.conf.json:43`). Not macOS-only and not unset — on Linux `"all"` means deb + rpm + AppImage. |
| Does `mix ex_tauri.build` rebuild the release? | **Yes.** `ExTauri.run/1` calls `wrap()`, which shells out to `mix release desktop --overwrite` and then copies `burrito_out/desktop_<triple>` to `desktop-<triple>` (`ExTauri.wrap/0, deps/ex_tauri/lib/ex_tauri.ex:245`). |
| Is the Tauri CLI available in CI? | **No.** `tauri_cli_path!()` raises unless `_build/_tauri/bin/cargo-tauri` exists, and only `mix ex_tauri.install` puts it there. |
| Which system packages does *this* lockfile need? | Derived below (§7), not copied from Tauri's prerequisites page. |
| Does the .deb declare its runtime dependencies? | **No, not by default.** See §5. |

## 3. Scope: one arch, on pushes to main

The bundle steps run only when all three hold:

```
github.event_name == 'push'  &&  github.ref == 'refs/heads/main'  &&  matrix.target == 'x86_64-unknown-linux-gnu'
```

Everything already in the job stays unconditional, so pull requests and the aarch64 leg are exactly
what they are today. The reason is cost (§9): a Tauri release build compiles 338 crates and cannot
be cached (§10), which takes a ~1-minute job to an estimated 9–15 minutes.

A second reason emerged while designing the CLI install and is worth recording, because it makes
the arch restriction cheaper than it looks. **Tauri publishes no prebuilt `cargo-tauri` for
`aarch64-unknown-linux-gnu`.** The `tauri-cli-v2.11.4` release ships
`cargo-tauri-x86_64-unknown-linux-gnu.tgz` and `cargo-tauri-riscv64gc-unknown-linux-gnu.tgz`, and
those are the only Linux assets. Bundling on arm64 would therefore need a
`cargo install tauri-cli` — several minutes of compilation and a cache to hide it — on top of the
Rust build. The accepted consequence is that **the arm64 bundle is never built or tested**; see §10.

The cost is paid where nothing waits on it: `deploy` keeps `needs: [check]`, unchanged. `ci.yml`
already states that the desktop binaries are a separate product and deliberately not a gate on
deployability, and the bundle is the same product.

## 4. Format: `deb` only

Passed as `mix ex_tauri.build --ci --bundles deb`. **`bundle.targets` stays `"all"`**, so a local
macOS build still produces `.app` and `.dmg` exactly as it does today; the narrowing is a CI
argument, stated where its reason lives.

**Why deb.** Tauri's deb bundler writes the archive in-process. `debian.rs` assembles the control
file and the data tarball from Rust — no external tooling, no network, nothing to be unavailable.

**Why not AppImage.** Its bundler downloads five artefacts *during the build*
(`appimage/linuxdeploy.rs`): `AppRun-x86_64` and `linuxdeploy-x86_64.AppImage` from
`tauri-apps/binary-releases`, `linuxdeploy-plugin-appimage` from AppImageKit, and two plugin
scripts from `raw.githubusercontent.com/tauri-apps/linuxdeploy-plugin-{gtk,gstreamer}/**master**/`.
That last pair is an unpinned mutable branch: the build can break with no change to this repository
and no advisory to explain it. That is a different and worse thing than `deps.audit` turning red on
a real advisory, which `mix.exs` argues is the point of a gate. (The commonly-cited FUSE problem on
Ubuntu 24.04 is *not* among the reasons — `linuxdeploy.rs:191` sets `APPIMAGE_EXTRACT_AND_RUN=1`.)

**Why not rpm.** It is also pure Rust and nearly free, but there is no consumer for it. Adding it
later is a one-word change to `--bundles`.

**What deb does not cover.** A `.deb` serves Debian and Ubuntu and nothing else. AppImage and
Flatpak are the formats that reach other distributions. That gap is real and accepted for now; see
§11.

## 5. What the .deb declares about itself

Two fields, neither of which is derived from the build. One is absent by default; the other is read
from whichever of several disagreeing declarations happens to win.

### Dependencies

`debian.rs:204` reads `settings.deb().depends` and writes a `Depends:` field only if it is
non-empty. With `bundle.linux` unset — which is the state today — **the generated .deb has no
`Depends:` field at all.** It installs cleanly onto a machine with no WebKit and then fails at the
dynamic linker. Nothing in the build notices, because the build never consults the metadata.

`src-tauri/tauri.conf.json` therefore gains, between `icon` and `targets`:

```json
"linux": {
  "deb": {
    "depends": ["libwebkit2gtk-4.1-0", "libc6 (>= 2.39)"],
    "recommends": ["libayatana-appindicator3-1"]
  }
}
```

`libwebkit2gtk-4.1-0` is deliberately the only hard *library* dependency. It transitively pulls gtk3, glib,
gio, gobject, cairo, pango, atk, gdk-pixbuf and libsoup3 — every pkg-config name the build probes
(§7) except dbus, which is present on any system with a desktop session. Naming gtk directly would
be worse, not better: Ubuntu's 64-bit-time transition renamed the runtime package to
`libgtk-3-0t64` on 24.04 while Debian 12 still calls it `libgtk-3-0`, so a literal gtk dependency
is unsatisfiable on one of them. `libwebkit2gtk-4.1-0` keeps its name across both.

appindicator is `recommends` rather than `depends` because `libappindicator-sys` 0.9.0 has no
`build.rs` — it `dlopen`s `libayatana-appindicator3.so.1` through `libloading`, and the panic on
failure fires only when the tray API is first called. `src-tauri/src/main.rs` builds a tray solely
in response to a `set_tray` command from Elixir, and no Elixir code sends one, so the path is
unreachable today. A hard dependency would refuse to install over a reachable-in-principle,
never-reached code path.

`libc6 (>= 2.39)` is the second hard dependency, and it encodes a constraint nothing else in the
pipeline expresses. Building on `ubuntu-24.04` stamps that runner's glibc into the binaries;
measured against the archives, Ubuntu 24.04 ships **2.39**, Debian 12 ships **2.36**, Debian 13
**2.41** and Debian 14 **2.42**. So without a declared bound the package installs cleanly on Debian
12 and then dies at the dynamic linker with `GLIBC_2.39 not found` — the same build-green,
run-broken shape as the missing `Depends:` field, and equally invisible to CI. Declaring it turns a
first-launch crash into an `apt` refusal.

**The bound is the build host's version, not a measurement of the binaries.** `dpkg-shlibdeps` is
what computes a true minimum from the symbols actually referenced, and Tauri's bundler never runs
it. `2.39` is therefore an upper estimate of the real requirement and may refuse installs that
would in fact have worked. That trade was made deliberately — a false refusal is a clear message,
where the alternative failure is a crash on first launch — but it is an estimate, and an audit of
the built binaries' symbol requirements would allow a lower, truer bound.

All three package names were verified present in Ubuntu 24.04 (noble), Debian 12 (bookworm),
Debian 13 (trixie) and Debian 14 (forky).

**Measured against the built package, Tauri appends its own dependencies to ours** — and that
changes what our declarations are worth. The shipped control file reads:

```
Depends: libwebkit2gtk-4.1-0, libc6 (>= 2.39), libayatana-appindicator3-1, libwebkit2gtk-4.1-0, libgtk-3-0
Recommends: libayatana-appindicator3-1
```

The last three entries are the CLI's, hardcoded at `crates/tauri-cli/src/interface/rust.rs:1426`,
`:1443` and `:1444`. Three consequences:

* **Our `libwebkit2gtk-4.1-0` is redundant** — hence the duplicate. Harmless to `apt`, but it is
  belt-and-braces rather than the load-bearing entry this section presented it as.
* **The `recommends` reasoning above is moot.** Tauri hard-`Depends` on
  `libayatana-appindicator3-1` regardless, so the careful `recommends`-not-`depends` argument
  changes nothing about the installed result. It is left in place because it costs nothing and
  documents our intent, but Tauri decides.
* **`libc6 (>= 2.39)` is the only entry that is genuinely ours,** which makes §10's glibc-floor
  bullet the real payload of this whole section.

And a caution above turns out to be unnecessary: Tauri names `libgtk-3-0` directly, the very thing
this section avoided over Ubuntu's `t64` rename. It resolves anyway — `libgtk-3-0t64` in noble
declares `Provides: libgtk-3-0 (= 3.24.41-4ubuntu1)`, verified against the archive's own
`Packages` index, and it is the only provider. The t64 transition kept the compatibility name.

### Version

This project stores its version in four places, and they already disagree:

| declaration | value | what it drives |
|---|---|---|
| `mix.exs:7` | `0.1.0` | the Mix release version → Burrito's payload cache key, `desktop_erts-17.0.4_0.1.0` |
| `src-tauri/tauri.conf.json:47` | `0.1.0` | the .deb filename and its control `Version:` field; the .dmg name; `CFBundleShortVersionString` |
| `src-tauri/Cargo.toml:3` | **`0.2.0`** | the Rust crate version — currently read by nothing that ships |
| `src-tauri/Cargo.lock:69` | **`0.2.0`** | derived from `Cargo.toml` by cargo, but tracked, and read by the `rust advisory` job |

The Cargo value is inert but armed. `rust.rs:1093` resolves the bundle version as
`config.version.clone().unwrap_or_else(|| <cargo package.version>)`, so removing or blanking
`"version"` in `tauri.conf.json` promotes the already-wrong `0.2.0` to naming every artifact,
silently.

**This change aligns `Cargo.toml` to `0.1.0`** and regenerates `Cargo.lock`, which carries the crate
version too. Down rather than up: `0.1.0` is what the two declarations that actually ship agree on,
and `0.2.0` was never a deliberate release of anything.

Aligning is not the same as keeping aligned, which is what §6 is for.

## 6. One version, checked by `mix check`

Aligning `Cargo.toml` once resets the clock on the same drift. The guard is a step in the existing
gate, **not a new git hook**: `.githooks/pre-push` is already a wrapper around `mix check` and
nothing else, so a step added to that alias is picked up by the hook with no edit to it, and by CI,
whose 1.20.2 matrix leg runs `mix check` verbatim. A hook-only check would be a gate that runs on a
laptop and not on a runner — precisely what `ci.yml`'s comment on the alias argues against.

`mix.exs` gains a `&check_versions/1` at the head of the `check:` alias, following the
`&install_git_hooks/1` precedent already in `setup:`. It reads four sites and raises unless all four
agree:

| site | read by |
|---|---|
| `mix.exs` project version | `Mix.Project.config()[:version]` — no parsing; the check runs inside the file it is checking |
| `src-tauri/tauri.conf.json` | `Jason.decode!` |
| `src-tauri/Cargo.toml` | regex, anchored inside the `[package]` table |
| `src-tauri/Cargo.lock` | regex on the `armchair_metropolist` `[[package]]` block |

Cargo.lock is derived from Cargo.toml, but is checked anyway: editing the manifest without running
cargo leaves the lock stale, and the `rust advisory` job reads the lock.

**Scope of the check, deliberately narrow.** Every other version-shaped string in the tree is a
*tool* version, not the product's — `config/config.exs` pins the Tauri CLI, tailwind and daisyui;
`ci.yml` pins Elixir, OTP and Zig; `.claude/launch.json` carries a launch-config schema version.
Including them would make the check noise, and a check that cries wolf gets bypassed, which is the
reasoning `.githooks/pre-commit` already applies to its secret patterns.

**It runs first in the alias** — it is milliseconds, and the same argument the alias already makes
for putting the security checks ahead of the suite applies with more force here.

**What it does not catch.** Drift between files, not staleness across builds. Four files agreeing on
`0.1.0` is the state we are already in for three of them, and the hazard in §10 is shipping two
*different* builds under one version, which Burrito's payload cache turns into an update that
silently does not apply. No alignment check can see that; only a release tag can. This does not
discharge the release-tagging work.

**On regex-parsing TOML.** Tolerable rather than good: both Cargo files are cargo-generated with
stable formatting, and a pattern that stops matching raises rather than passing quietly. That
failure direction is not theoretical here — `.githooks/pre-commit` carries a comment about the
secret scan silently matching nothing for exactly this class of reason.

## 7. System packages, derived from the lockfile

Not copied from Tauri's prerequisites page. Established by `cargo fetch --target
x86_64-unknown-linux-gnu` and then reading every `[package.metadata.system-deps]` table and every
`pkg_config::…probe(…)` call in the 338-crate Linux tree:

| pkg-config name | from | apt package |
|---|---|---|
| `gtk+-3.0`, `gdk-3.0`, `gdk-x11-3.0`, `atk`, `cairo`, `cairo-gobject`, `pango`, `gdk-pixbuf-2.0`, `gio-2.0`, `glib-2.0`, `gobject-2.0` | gtk-sys 0.18.2 and the gtk-rs 0.18 family | `libgtk-3-dev` |
| `webkit2gtk-4.1`, `javascriptcoregtk-4.1`, `libsoup-3.0` | webkit2gtk-sys 2.0.2, javascriptcore-rs-sys 1.1.1, soup3-sys 0.5.0 | `libwebkit2gtk-4.1-dev` |
| `dbus-1` | libdbus-sys 0.2.7 ← tao 0.35.3 ← tauri-runtime-wry | `libdbus-1-dev` |
| `ayatana-appindicator3-0.1` | **the `cargo-tauri` CLI itself**, not any crate — `pkgconfig_utils::get_appindicator_library_path`, `crates/tauri-cli/src/interface/rust.rs:1711-1722` | `libayatana-appindicator3-dev` |

Differences from Tauri's published apt line, all of them measured — including one where
that page was right and this derivation was wrong:

* **`libxdo-dev` is not needed.** There is no `xdo` crate anywhere in `Cargo.lock`.
* **`libayatana-appindicator3-dev` IS needed — and a dependency-graph derivation cannot discover
  that.** This was originally recorded here as unnecessary, on the correct but irrelevant grounds
  that `libappindicator-sys` 0.9.0 has no `build.rs` and `dlopen`s the library (§5). That is a fact
  about *compiling*. The consumer is the **Tauri CLI**, which is a prebuilt binary downloaded
  separately and therefore absent from `Cargo.lock`: it shells out to `pkg-config` for
  `ayatana-appindicator3-0.1`, falls back to `appindicator3-0.1`, and **panics** when neither `.pc`
  file exists. Run `30805473925` on main is the evidence — the Rust compile finished cleanly in
  4m03s and `cargo-tauri` then aborted with exit 134 and `Can't detect any appindicator library`.
  The lesson generalises: enumerate build inputs by **process** — every executable the build runs —
  not by dependency graph, and treat a docs/derivation disagreement as a signal that the docs may
  describe a consumer the graph cannot see.
* **`libdbus-1-dev` *is* needed and Tauri's list omits it.** This is the dangerous direction: the
  omission surfaces as a `system-deps` probe failure hundreds of crates into a release build.
* **`libssl-dev` is not needed.** There is no `openssl-sys` anywhere in the tree.

## 8. Shape

A job-level `env` entry states the condition once, since five steps share it:

```yaml
    env:
      MIX_ENV: prod
      BUNDLE: ${{ github.event_name == 'push' && github.ref == 'refs/heads/main' && matrix.target == 'x86_64-unknown-linux-gnu' }}
```

and each new step carries `if: env.BUNDLE == 'true'`. The steps, appended after the existing
sidecar verify and upload:

1. **Install the headers.** `apt-get update && apt-get install -y --no-install-recommends
   libwebkit2gtk-4.1-dev libgtk-3-dev libdbus-1-dev`.
2. **Install the Tauri CLI.** Download
   `https://github.com/tauri-apps/tauri/releases/download/tauri-cli-v2.11.4/cargo-tauri-x86_64-unknown-linux-gnu.tgz`
   and `tar -xzf … -C _build/_tauri/bin cargo-tauri`. Verified by download: the tarball is 8.3 MB
   and contains a bare `cargo-tauri` executable plus two licence files, so extraction lands the
   binary at exactly the path `ExTauri.installation_path()/bin/cargo-tauri` resolves to.
3. **`mix ex_tauri.build --ci --bundles deb`.**
4. **Verify the .deb** (§12).
5. **Upload** as `desktop-bundle-x86_64-unknown-linux-gnu`.

Three things this deliberately does *not* do.

**It does not run `mix ex_tauri.install`.** That is the supported way to get the CLI, and it is
Igniter-driven: it rewrites `config/config.exs`, `mix.exs` and — the hazard —
`src-tauri/src/main.rs` from a template. `docs/superpowers/2026-07-30-follow-ups.md` ("Desktop
release env staleness") records that `main.rs` is hand-edited to inject `ARMCHAIR_DESKTOP=1`, and
that without it a release silently reverts to the server defaults. CI performs the one part of that
installer it actually needs, which is placing a binary.

**It does not guard the extract with `test -x`.** `_build` is cached, so a guard would let a CLI
left behind by an older version pin survive a bump, silently. Re-extracting 8.3 MB costs seconds
and has no such failure mode.

**It does not remove the existing `mix release desktop` step,** even though `mix ex_tauri.build`
re-runs it internally. Folding them would save 69 s on the one path where the bundle is built, and
would cost the guarantee that a wrapper failure can never take the sidecar's arch check and
artifact down with it. The sidecar build is green on both arches today and the Linux wrapper build
is unproven; keeping the proven step standing on its own is worth 69 s.

## 9. Effect on runtime

| path | today | after |
|---|---|---|
| any pull request, either arch | 57 s / 95 s | **unchanged** |
| push to main, aarch64 | 57 s | **unchanged** |
| push to main, x86_64 | 95 s | **374 s / 6 m 14 s (measured)** |
| `deploy` starts / finishes on main | T+54 s / T+107 s | **unchanged** |

Measured on run `30806469213`, the first green bundle: job total **374 s**, of which
`mix ex_tauri.build` was **240 s** (the Rust release compile itself reported `Finished in 4m 03s`
inside it), apt **66 s**, the prebuilt Tauri CLI download **under 1 s**, and the duplicated Burrito
work **35 s**. That lands at the low end of the 9–15 minute estimate this section originally
carried. The resulting `.deb` is **23 MB**.

The row that matters is the last one. `deploy` needs only `check`, whose slower leg finishes at
~T+50 s, so
a release still ships about as fast as it does today. What changes is when the *run* reports
complete — from ~2 minutes to ~15.

## 10. Known limitations, accepted

* **The supported floor is Ubuntu 24.04+ and Debian 13+, set by the runner rather than by us.**
  The `.deb` inherits the build host's glibc 2.39, which excludes Debian 12 (glibc 2.36) whatever
  the control file says. §5 declares `libc6 (>= 2.39)` so the exclusion is an `apt` refusal rather
  than a crash, but that only reports the limit — it does not widen it. Widening would mean
  building on an older base, which collides with the constraint that each arch builds natively on
  its own runner.
* **The arm64 bundle is never built.** aarch64 keeps producing a sidecar and nothing more. An arm
  Linux desktop user has no artifact, and an arch-specific break in the Tauri build will not be
  caught. Reversing this means paying a `cargo install tauri-cli` on that leg (§3).
* **No bundle is built on pull requests.** A change that breaks the wrapper lands on main and is
  discovered by the post-merge run. Consistent with the desktop job already being non-blocking, but
  it does mean the break is found after the fact.
* **The Rust build is not cached.** `src-tauri/target/release` is 2.3 GB; against a 10 GB
  repository-wide cache budget already holding four mix caches, caching it is not viable, and
  neither is the up/download time. The full compile is paid on every push to main. If this becomes
  painful, `~/.cargo/registry` alone is small enough to cache and is the first thing to try.
* **The Rust toolchain is whatever the runner image ships.** No `dtolnay/rust-toolchain` pin. A
  toolchain that is too old fails as a compile error rather than a silent wrong result, which is an
  acceptable failure mode for this job.
* **The Tauri CLI version is pinned in the workflow at 2.11.4 while a laptop's `mix
  ex_tauri.install` resolves `^2.5.1` freshly.** CI is therefore more reproducible than a laptop and
  can drift behind it. Review trigger: bump the pin when `config :ex_tauri, :version` moves, or when
  a bundler fix is wanted.
* **The CLI tarball is not checksum-verified.** Tauri publishes no per-asset digest alongside it.
  The download is HTTPS from the vendor's own release tag; that is the same trust already extended
  to `taiki-e/install-action` in the `rust-advisory` job.
* **The sidecar installs to `usr/bin/desktop`** — measured, no longer an open question. The Tauri
  host sits beside it at `usr/bin/armchair_metropolist`. §12's check still asserts the filename
  rather than the full path, which costs nothing and keeps it robust to Tauri moving the directory.
* **`version` in `mix.exs` becomes load-bearing the moment anyone installs this.** A production
  Burrito binary unpacks its payload exactly once, keyed on nothing but
  `<name>_erts-<erts>_<app version>`, and `evict_burrito_payload_cache/1` clears only the *build*
  machine — see `docs/superpowers/2026-07-30-follow-ups.md`. `version` has been `0.1.0` throughout.
  Ship two different 0.1.0 debs and the second one installs new code that never runs. This is not
  introduced by this change, but this change is what makes it reachable by someone other than us.

  **The intended fix is tag-driven GitHub Releases, spec'd separately once the .deb is proven.**
  That is what turns the version from an afterthought into the trigger, and its first step is §6's
  check with the tag itself added as a fifth site — the alignment guard already exists by then, and
  the release job only has to extend it. It also resolves the first two limitations
  in this list: at release cadence the ~5-minute `cargo install tauri-cli` needed for arm64 is
  affordable, and a Release is permanent and public where these artifacts expire in 14 days and need
  repository access to download.

## 11. Flatpak, deferred

Considered and deliberately not built now. Recording why, because the reasons are not obvious and
the question will come back.

**It is not a Tauri bundle target.** `PackageType` (`tauri-bundler/src/bundle/settings.rs:26`)
enumerates `deb`, `ios`, `msi`, `app`, `rpm`, `appimage`, `dmg`, `updater`. There is no
`--bundles flatpak`. Tauri's Flatpak guide exists in `tauri-apps/tauri-docs` but is marked
`draft: true` and the published page returns 404.

**It consumes the .deb.** The guide's approach is a separate `flatpak-builder` manifest whose source
is the built .deb, unpacked with `ar -x` and installed into `/app` against `org.gnome.Platform//46`.
So this design's output is Flatpak's input, and building the deb first loses nothing.

**What it would additionally cost:** `flatpak` and `flatpak-builder` on the runner; a
`flatpak install org.gnome.Platform//46 org.gnome.Sdk//46`, on the order of 1.5–2 GB per run and
uncacheable for the same budget reason as §10; a hand-authored AppStream MetaInfo XML as a new
tracked source file; and bubblewrap plus user namespaces, which work on the `ubuntu-24.04` host
runner but stop working if the job is ever containerised.

**The two risks that decide it, both invisible to CI:**

1. *The glibc floor.* Repackaging a .deb moves a binary built against the build distro's libc into
   the runtime's userspace. Ubuntu 24.04's `libc6` is **2.39** (verified via packages.ubuntu.com).
   If the GNOME Platform runtime supplies an older one, the Tauri host dies at startup with
   `GLIBC_2.39 not found` — and `flatpak-builder` still exits 0, because all it did was copy files.
   The runtime's glibc version was **not** verified during this design and is the first thing to
   establish if we pursue this.
2. *The Burrito payload cache across updates.* Flatpak gives each app a persistent
   `~/.var/app/<id>/data` that survives updates, and `$XDG_DATA_HOME` is where the sidecar unpacks.
   Combined with the `version`-only cache key in §10's last bullet, a Flatpak update ships new code
   that does not run. This is the bug that already cost a day here once.

**And the channel is the point.** A `.flatpak` bundle file that is not on Flathub has to be
side-loaded, which is strictly worse than a .deb for the same person. Flathub is what makes the
format worth the machinery, and submission there is a separate, review-gated process.

**Revisit when** the deb pipeline is green, and start by verifying the runtime's glibc against
2.39 and by deciding the release-versioning policy that risk 2 depends on.

## 12. Verification

By mutation, not by observing a green run — the standing rule in this repository is that a check
which passes because it is doing nothing looks identical to one that passes because it is satisfied.

Each of these is asserted by the "Verify the .deb" step, and each must be shown to fail:

| assertion | mutation that must turn it red |
|---|---|
| A `.deb` exists under `src-tauri/target/release/bundle/deb/` | point the glob at a bogus filename |
| `bundle/appimage/` and `bundle/rpm/` do **not** exist | drop `--bundles deb`; both must appear, proving the flag was doing something |
| `dpkg-deb --field <deb> Depends` is non-empty | remove `bundle.linux.deb.depends` from `tauri.conf.json`; this is the standing regression test for §5 |
| `dpkg-deb --contents <deb>` lists a file named `desktop` | assert a name that is not there, and confirm the failure prints the full contents listing so the real path is discoverable |
| `dpkg-deb --field <deb> Version` is `0.1.0` | this one is not mutated but observed: it proves at runtime that `tauri.conf.json` is the authority and `Cargo.toml` is the unused fallback, which §5 establishes only by reading `rust.rs:1093` |

§6's alignment check is mutated independently of the bundle, since it runs in `mix check` and needs
no Linux runner. Set each of the four sites to a different version **one at a time** and confirm
`mix check` goes red for each — four separate mutations, not one. A single mutation would leave it
unknown whether the other three sites are read at all, which is the failure this repository has hit
repeatedly: a check that passes because it is doing nothing looks exactly like one that is satisfied.
Then confirm the aligned tree goes green, so the red is carried by the mutation and not by the check
being broken outright.

Two things this cannot verify, stated rather than papered over:

* **`mix ex_tauri.build` does complete on Linux — proven, but it took two runs.** The first push to
  main (`30805473925`) went red: the Rust compile succeeded in 4m03s and `cargo-tauri` then panicked
  with `Can't detect any appindicator library`, because §7's dependency-graph derivation could not
  see a requirement belonging to the CLI binary. With `libayatana-appindicator3-dev` added, run
  `30806469213` produced, verified and uploaded a 23 MB `.deb`.
* **All four remaining assertions in `scripts/verify-deb.sh` are now mutation-verified** against
  that artifact, on a laptop with `dpkg-deb` installed: each of the four mutations turned it red and
  the unmutated script still passed. Inspecting the real package also exposed a latent defect the
  mutations could not — the sidecar check parsed paths with `awk '{print $NF}'`, which truncates
  `usr/share/applications/Armchair Metropolist.desktop` to `Metropolist.desktop`; a path like
  `.../Armchair desktop` would have truncated to exactly `desktop` and passed vacuously. Fixed to
  reassemble fields 6..NF.
* **Whether the installed application runs.** Nothing here launches the .deb. `Depends` being
  present proves the metadata exists, not that it is sufficient, and the tray code path in §5 is
  reasoned about rather than exercised. A headless smoke test — install, launch under xvfb, assert
  the sidecar's port opens — is the honest next increment and is out of scope here.
