# A Linux desktop bundle in CI — design

**Date:** 2026-08-02
**Status:** approved, not yet implemented

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

Job timings from run `30771595298` (warm `_build` cache), which is the baseline every figure in §8
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
| What does `bundle.targets` declare? | **`"all"`** (`src-tauri/tauri.conf.json:37`). Not macOS-only and not unset — on Linux `"all"` means deb + rpm + AppImage. |
| Does `mix ex_tauri.build` rebuild the release? | **Yes.** `ExTauri.run/1` calls `wrap()`, which shells out to `mix release desktop --overwrite` and then copies `burrito_out/desktop_<triple>` to `desktop-<triple>` (`deps/ex_tauri/lib/ex_tauri.ex:241`). |
| Is the Tauri CLI available in CI? | **No.** `tauri_cli_path!()` raises unless `_build/_tauri/bin/cargo-tauri` exists, and only `mix ex_tauri.install` puts it there. |
| Which system packages does *this* lockfile need? | Derived below (§6), not copied from Tauri's prerequisites page. |
| Does the .deb declare its runtime dependencies? | **No, not by default.** See §5. |

## 3. Scope: one arch, on pushes to main

The bundle steps run only when all three hold:

```
github.event_name == 'push'  &&  github.ref == 'refs/heads/main'  &&  matrix.target == 'x86_64-unknown-linux-gnu'
```

Everything already in the job stays unconditional, so pull requests and the aarch64 leg are exactly
what they are today. The reason is cost (§8): a Tauri release build compiles 338 crates and cannot
be cached (§9), which takes a ~1-minute job to an estimated 9–15 minutes.

A second reason emerged while designing the CLI install and is worth recording, because it makes
the arch restriction cheaper than it looks. **Tauri publishes no prebuilt `cargo-tauri` for
`aarch64-unknown-linux-gnu`.** The `tauri-cli-v2.11.4` release ships
`cargo-tauri-x86_64-unknown-linux-gnu.tgz` and `cargo-tauri-riscv64gc-unknown-linux-gnu.tgz`, and
those are the only Linux assets. Bundling on arm64 would therefore need a
`cargo install tauri-cli` — several minutes of compilation and a cache to hide it — on top of the
Rust build. The accepted consequence is that **the arm64 bundle is never built or tested**; see §9.

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
§10.

## 5. The .deb declares no dependencies unless we say so

`debian.rs:204` reads `settings.deb().depends` and writes a `Depends:` field only if it is
non-empty. With `bundle.linux` unset — which is the state today — **the generated .deb has no
`Depends:` field at all.** It installs cleanly onto a machine with no WebKit and then fails at the
dynamic linker. Nothing in the build notices, because the build never consults the metadata.

`src-tauri/tauri.conf.json` therefore gains, between `icon` and `targets`:

```json
"linux": {
  "deb": {
    "depends": ["libwebkit2gtk-4.1-0"],
    "recommends": ["libayatana-appindicator3-1"]
  }
}
```

`libwebkit2gtk-4.1-0` is deliberately the only hard dependency. It transitively pulls gtk3, glib,
gio, gobject, cairo, pango, atk, gdk-pixbuf and libsoup3 — every pkg-config name the build probes
(§6) except dbus, which is present on any system with a desktop session. Naming gtk directly would
be worse, not better: Ubuntu's 64-bit-time transition renamed the runtime package to
`libgtk-3-0t64` on 24.04 while Debian 12 still calls it `libgtk-3-0`, so a literal gtk dependency
is unsatisfiable on one of them. `libwebkit2gtk-4.1-0` keeps its name across both.

appindicator is `recommends` rather than `depends` because `libappindicator-sys` 0.9.0 has no
`build.rs` — it `dlopen`s `libayatana-appindicator3.so.1` through `libloading`, and the panic on
failure fires only when the tray API is first called. `src-tauri/src/main.rs` builds a tray solely
in response to a `set_tray` command from Elixir, and no Elixir code sends one, so the path is
unreachable today. A hard dependency would refuse to install over a reachable-in-principle,
never-reached code path.

## 6. System packages, derived from the lockfile

Not copied from Tauri's prerequisites page. Established by `cargo fetch --target
x86_64-unknown-linux-gnu` and then reading every `[package.metadata.system-deps]` table and every
`pkg_config::…probe(…)` call in the 338-crate Linux tree:

| pkg-config name | from | apt package |
|---|---|---|
| `gtk+-3.0`, `gdk-3.0`, `gdk-x11-3.0`, `atk`, `cairo`, `cairo-gobject`, `pango`, `gdk-pixbuf-2.0`, `gio-2.0`, `glib-2.0`, `gobject-2.0` | gtk-sys 0.18.2 and the gtk-rs 0.18 family | `libgtk-3-dev` |
| `webkit2gtk-4.1`, `javascriptcoregtk-4.1`, `libsoup-3.0` | webkit2gtk-sys 2.0.2, javascriptcore-rs-sys 1.1.1, soup3-sys 0.5.0 | `libwebkit2gtk-4.1-dev` |
| `dbus-1` | libdbus-sys 0.2.7 ← tao 0.35.3 ← tauri-runtime-wry | `libdbus-1-dev` |

Four differences from Tauri's published apt line, all of them measured:

* **`libxdo-dev` is not needed.** There is no `xdo` crate anywhere in `Cargo.lock`.
* **`libayatana-appindicator3-dev` is not needed at build time**, for the `dlopen` reason in §5.
* **`libdbus-1-dev` *is* needed and Tauri's list omits it.** This is the dangerous direction: the
  omission surfaces as a `system-deps` probe failure hundreds of crates into a release build.
* **`libssl-dev` is not needed.** There is no `openssl-sys` anywhere in the tree.

## 7. Shape

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
4. **Verify the .deb** (§11).
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

## 8. Effect on runtime

| path | today | after |
|---|---|---|
| any pull request, either arch | 57 s / 95 s | **unchanged** |
| push to main, aarch64 | 57 s | **unchanged** |
| push to main, x86_64 | 95 s | **~9–15 min (estimated)** |
| `deploy` starts / finishes on main | T+54 s / T+107 s | **unchanged** |

The estimate is the one number here that is not measured, and it cannot be measured from this
machine. Its basis: 338 crates compiled in release mode on a 4-vCPU runner, plus ~60 s of apt, plus
the 69 s of duplicated Burrito work from §7, plus bundling. `src-tauri/target/release` is 2.3 GB
locally after a comparable macOS build, which is a second reason to expect minutes rather than
seconds.

The row that matters is the last one. `deploy` needs only `check`, whose slower leg finishes at
~T+50 s, so
a release still ships about as fast as it does today. What changes is when the *run* reports
complete — from ~2 minutes to ~15.

## 9. Known limitations, accepted

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
* **The sidecar's install path inside the .deb is unverified.** On macOS Tauri strips the target
  triple and installs it as `Contents/MacOS/desktop`, so the *name* is known to be `desktop`; the
  Linux directory is not. §11's check asserts the filename rather than the path for that reason.
* **`version` in `mix.exs` becomes load-bearing the moment anyone installs this.** A production
  Burrito binary unpacks its payload exactly once, keyed on nothing but
  `<name>_erts-<erts>_<app version>`, and `evict_burrito_payload_cache/1` clears only the *build*
  machine — see `docs/superpowers/2026-07-30-follow-ups.md`. `version` has been `0.1.0` throughout.
  Ship two different 0.1.0 debs and the second one installs new code that never runs. This is not
  introduced by this change, but this change is what makes it reachable by someone other than us.

## 10. Flatpak, deferred

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
uncacheable for the same budget reason as §9; a hand-authored AppStream MetaInfo XML as a new
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
   Combined with the `version`-only cache key in §9's last bullet, a Flatpak update ships new code
   that does not run. This is the bug that already cost a day here once.

**And the channel is the point.** A `.flatpak` bundle file that is not on Flathub has to be
side-loaded, which is strictly worse than a .deb for the same person. Flathub is what makes the
format worth the machinery, and submission there is a separate, review-gated process.

**Revisit when** the deb pipeline is green, and start by verifying the runtime's glibc against
2.39 and by deciding the release-versioning policy that risk 2 depends on.

## 11. Verification

By mutation, not by observing a green run — the standing rule in this repository is that a check
which passes because it is doing nothing looks identical to one that passes because it is satisfied.

Each of these is asserted by the "Verify the .deb" step, and each must be shown to fail:

| assertion | mutation that must turn it red |
|---|---|
| A `.deb` exists under `src-tauri/target/release/bundle/deb/` | point the glob at a bogus filename |
| `bundle/appimage/` and `bundle/rpm/` do **not** exist | drop `--bundles deb`; both must appear, proving the flag was doing something |
| `dpkg-deb --field <deb> Depends` is non-empty | remove `bundle.linux.deb.depends` from `tauri.conf.json`; this is the standing regression test for §5 |
| `dpkg-deb --contents <deb>` lists a file named `desktop` | assert a name that is not there, and confirm the failure prints the full contents listing so the real path is discoverable |

Two things this cannot verify, stated rather than papered over:

* **Whether `mix ex_tauri.build` completes on Linux at all is unproven until the first push to
  main.** No container runtime is installed on the development machine — no `docker`, no `podman`;
  `colima` is present but not running — so there is no local Linux path to pre-flight it. The
  historically fragile part is already covered: the Linux *sidecar* is green on both arches, and the
  four `ex_tauri`/Burrito behaviours that had to be fixed to make the macOS build work
  (`docs/superpowers/2026-07-30-follow-ups.md`) are all in `mix.exs` and apply to every platform.
  What is genuinely new is the Rust link step and the bundler.
* **Whether the installed application runs.** Nothing here launches the .deb. `Depends` being
  present proves the metadata exists, not that it is sufficient, and the tray code path in §5 is
  reasoned about rather than exercised. A headless smoke test — install, launch under xvfb, assert
  the sidecar's port opens — is the honest next increment and is out of scope here.
