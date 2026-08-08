# Follow-ups after the initial build

**Date:** 2026-07-30 (desktop sections updated 2026-07-31)
**Branch:** merged to `main`
**Current state:** 148 tests pass (5 properties, 143 tests), `mix check` exits 0, coverage
92.78% gated at 90%. `Domain`, `Domain.Services` and `UseCases` are at 100%. The packaged macOS
`.app` builds, launches, and serves a live LiveView — see the desktop section below.

Everything below was found during implementation, triaged, and deliberately deferred. Nothing
here blocks merge. The four must-fixes from the final whole-branch review (adapter I/O errors,
adapter `latest` divergence, the `:erlang` purity gap, and a property-suite tautology) were all
fixed and mutation-verified before hand-off.

## Needs a decision from you

**The Gigalixir deploy: fixed in `eeb8296`, not yet confirmed green.** From at least `ad97ecc`
until then, every push to `main` merged code without shipping a release — `deploy to Gigalixir`
ended in `Sorry, we could not authenticate you.` while everything else passed (run `30764057877`:
both `mix check` matrix jobs and both Burrito builds green, this job alone red).

The cause was in the workflow, not the credential. `ci.yml` fed the *API key* into the flag that
wants the *account password*:

```yaml
GIGALIXIR_PASSWORD: ${{ secrets.GIGALIXIR_API_KEY }}   # before
GIGALIXIR_PASSWORD: ${{ secrets.GIGALIXIR_PASSWORD }}  # after, eeb8296
```

A matching `GIGALIXIR_PASSWORD` secret was added 2026-08-02. **The next push to `main` is the
first real test** — until one goes green, treat the deploy as unverified.

Two loose ends:

* `GIGALIXIR_API_KEY` is now referenced by nothing. Delete it, or keep it deliberately for the
  alternative below — an unused secret that looks live is a trap for the next reader.
* An account password in CI is not revocable without changing the account password. Gigalixir's
  own CI documentation avoids `login` entirely and embeds an API key in a git remote, which *is*
  independently revocable. It needs the email **URI-encoded** (`foo%40gigalixir.com`; an
  unencoded `@` breaks the URL):

  ```
  git remote add gigalixir https://$GIGALIXIR_EMAIL:$GIGALIXIR_API_KEY@git.gigalixir.com/$GIGALIXIR_APP_NAME.git
  git push -f gigalixir HEAD:refs/heads/main
  ```

  Worth revisiting if the password approach proves awkward; no reason to churn it while it works.

**Bundle identifier.** `src-tauri/tauri.conf.json` carries
`io.github.adsouza.armchair-metropolist`, derived from the `adsouza` GitHub account that owns the
remote. It drives macOS code signing and the app's data container, so it is awkward to change once
anything is signed — but nothing is signed yet, so switching it now is free.

`io.github.<account>` is the standard reverse-DNS form for a project hosted on GitHub with no
separate domain. **If you own a personal domain, prefer that instead** (e.g. `dev.adsouza.…` if you
hold `adsouza.dev`) — it is a one-line change in `tauri.conf.json`.

An earlier value, `ai.polynomic.armchair-metropolist`, was wrong: it was inferred from the session's
email address rather than from the account owning this repository. Commit authorship was never
affected — every commit on the branch is authored as the `adsouza` account.

## The production desktop build — working

`mix ex_tauri.build` now **completes** for the native macOS target and produces
`Armchair Metropolist.app` (23 MB) and `Armchair Metropolist_0.1.0_aarch64.dmg` (15 MB) under
`src-tauri/target/release/bundle/`. Verified: the `.dmg` is a real UDZO image; the `.app` contains
both the Tauri host and the Burrito sidecar (`Contents/MacOS/desktop`), both `arm64`; and
`CFBundleIdentifier` in the shipped `Info.plist` is `io.github.adsouza.armchair-metropolist`.

Getting the build to complete needed four fixes, three of which were `ex_tauri`/Burrito
behaviour that contradicts the documentation.

1. **ERTS pin.** Burrito requests the build machine's OTP version; 29.0.4 is unbuilt on the CDN.
   `custom_erts` now pins 29.0.3 per target. `ex_tauri` still prints
   *"Burrito may not have pre-compiled ERTS for OTP 29 yet. Production builds may fail"* — that
   warning is stale, and the build succeeds with the pin.
2. **Zig is required for every build**, not just cross-compilation as the docs claim. Burrito shells
   out to `zig build` unconditionally (`lib/steps/build/pack_and_build.ex`). Zig 0.16.0 installed,
   which is what Burrito 1.6 targets.
3. **Only the host target is declared by default.** `mix ex_tauri.build` builds every declared
   target, and cross-compiling Linux from macOS fails at Zig's link step
   (`compile exe desktop ReleaseSmall x86_64-linux 1 errors`). `BURRITO_ALL_TARGETS=1` opts back in.
4. **Burrito target keys must be Rust target triples.** `ex_tauri`'s `rename_burrito_output/0`
   looks for `burrito_out/desktop_<rustc host triple>`, so a friendly key like `macos_arm` builds
   fine and then dies on `could not copy from "burrito_out/desktop_aarch64-apple-darwin"`.

**Linux bundles now build in CI — proven 2026-08-03.** Cross-compilation from macOS still fails as
above, so each arch builds on its own runner. The `desktop` job in `.github/workflows/ci.yml` runs
`mix ex_tauri.build --ci --bundles deb` on x86_64 for pushes to `main`, and publishes a 23 MB `.deb`
as `desktop-bundle-x86_64-unknown-linux-gnu`. Design and rationale:
`docs/superpowers/specs/2026-08-02-linux-desktop-bundle-design.md`.

Measured: 374 s for the whole job, 240 s of it `mix ex_tauri.build` (the Rust release compile reports
`Finished in 4m 03s` inside that), 66 s of apt. The sidecar installs to `usr/bin/desktop` and the
Tauri host to `usr/bin/armchair_metropolist`.

**The trap that cost the first run.** The apt list was derived by enumerating every
`[package.metadata.system-deps]` table and `pkg_config` probe in the 338-crate Linux tree — and that
method structurally cannot find one of the requirements. `libayatana-appindicator3-dev` is needed by
the **Tauri CLI**, which we download as a prebuilt binary and which is therefore absent from
`Cargo.lock`: `pkgconfig_utils::get_appindicator_library_path`
(`crates/tauri-cli/src/interface/rust.rs:1711-1722`) shells out to `pkg-config` for
`ayatana-appindicator3-0.1`, falls back to `appindicator3-0.1`, and panics with `Can't detect any
appindicator library` when neither `.pc` file exists. The compile succeeded and the *bundler*
aborted with exit 134. `libappindicator-sys` 0.9 having no `build.rs` is true and irrelevant — it
describes compiling, not bundling. **Enumerate build inputs by process, not by dependency graph.**

**Two further things worth knowing before you touch this.** Tauri appends its own deb dependencies
to whatever `tauri.conf.json` declares (`rust.rs:1426`, `:1443`, `:1444`), so `libwebkit2gtk-4.1-0`
appears twice in the shipped `Depends:` and `libayatana-appindicator3-1` is a hard dependency
regardless of our `recommends`. Only `libc6 (>= 2.39)` is genuinely ours, and it encodes the real
constraint: the `.deb` inherits the runner's glibc, so it installs on Ubuntu 24.04+ and Debian 13+
but not Debian 12 (glibc 2.36). Tauri also names `libgtk-3-0` directly, which resolves anyway
because `libgtk-3-0t64` declares `Provides: libgtk-3-0`.

**Also: arm64 gets no bundle.** Tauri publishes no prebuilt `cargo-tauri` for
`aarch64-unknown-linux-gnu`, so that leg would need a multi-minute `cargo install` on top of the Rust
build. It still produces a sidecar.

### CRITICAL: a production Burrito binary unpacks its payload once, then never again

**This is the most important thing in this document.** If you change anything about the
desktop target, read it first. It is the reason the packaged app appeared broken for a long
time, and it will happily waste another day if you forget it.

A Burrito binary carries a compressed release and unpacks it to
`<app data>/.burrito/<name>_erts-<erts version>_<app version>`. `wrapper.zig` decides whether
to unpack with nothing more than *"does `_metadata.json` already exist in that directory"*
(lines 73–82), and the only other trigger is `wants_clean_install`, hardwired to
`!IS_PROD`. So **in a production build the payload is extracted exactly once.** The directory
name is the entire cache key: no payload hash, no build timestamp — notwithstanding the comment
above `get_install_dir` claiming it "combine[s] the hash of the payload", which the code below
it does not do.

`version` in `mix.exs` has been `0.1.0` throughout, so every rebuild was a **no-op at
runtime**. The sidecar kept executing the first build ever made. That is why fix after fix to
the desktop configuration changed nothing: the code doing the configuring was not in the
payload being run. Confirmed by reading the cached `_metadata.json`, which still named targets
`macos_arm`/`linux_x86` — keys renamed to Rust triples long before.

Nothing reports this. The launcher logs `Skipping archive unpacking, this machine already has
the app installed!` at **debug** level only, which the Tauri host never shows.

**The fix:** `mix.exs` runs `&evict_burrito_payload_cache/1` as the final release step, deleting
the matching install directory so the binary just built is the one that runs. If you ever need
to do it by hand:

```bash
rm -rf ~/Library/Application\ Support/.burrito/desktop_erts-*_0.1.0
```

(`./burrito_out/desktop_* maintenance uninstall` does the same but prompts for confirmation on
stdin, so it is useless from a script.)

Two smaller traps in the same area, both of which cost time:

* **`mix release desktop` alone is not enough to test the bundle.** Burrito writes
  `burrito_out/desktop_<triple>` with an *underscore*; Tauri's `externalBin` consumes
  `desktop-<triple>` with a *hyphen*, and only `mix ex_tauri.build` performs that rename. Run
  `mix release desktop` and then launch the hyphenated file and you are testing an older binary.
* **`IO.puts` during `Application.start/2` does not reach the sidecar's stdout**, though
  `Logger` does. An `IO.puts` probe in the boot path proves nothing either way — see the
  correction below.

### Correction: `config/runtime.exs` *is* evaluated in a Burrito sidecar

An earlier version of this document claimed, in a section marked CRITICAL, that
`config/runtime.exs` is never evaluated in a packaged sidecar. **That was wrong.** It is
evaluated. Verified the right way round this time — by setting a marker key in `runtime.exs` and
reading it back from inside the running binary (`[probe] runtime.exs marker: true`) rather than
by trying to print from it.

The false conclusion came from two compounding faults, and both are worth remembering because
either alone would have produced the same wrong answer:

1. the probe was an `IO.puts` at the top of `runtime.exs`, and that output does not surface from
   a sidecar — so its absence meant nothing; and
2. the payload containing the probe was stale anyway, per the section above.

The original symptom — the packaged app behaving as the *server* target, on local Postgres —
had a simpler cause: `ARMCHAIR_DESKTOP` was not in the sidecar's environment at all until
`src-tauri/src/main.rs` was changed to inject it, because `config :ex_tauri, :sidecar_env` is
read only at install time. With the marker absent, the `if desktop?` block in `runtime.exs`
correctly did nothing.

`Desktop.Config.apply!/0` is still where desktop settings belong, but for ordinary reasons
rather than dramatic ones: a config file cannot be reached from a test, and one definition
cannot drift from itself. The duplicate block in `runtime.exs` has been removed.

### CRITICAL: the sidecar needs `--no-halt` or it exits 0 immediately

Separate bug, and this one is real — **re-verified after the payload-cache fix**, on a freshly
extracted payload, precisely because the stale-payload discovery cast doubt on every earlier
measurement. Without `--no-halt` the sidecar exits 0 with no listener; with it, the endpoint
stays up.

Burrito's `erl` line ends in `-s elixir start_cli`. `start_cli` treats its extra arguments as
scripts to run and then **halts**. ex_tauri spawns the sidecar with no arguments at all, so the
sidecar booted Phoenix, logged `Running ...Endpoint`, and exited with **code 0** about a second
later. A Mix release's own `start` command avoids exactly this by passing `--no-halt`.

`src-tauri/src/main.rs` now spawns the sidecar with `.args(["--no-halt"])`. Verified: the port
goes from *never* reachable to reachable in 0.81s, and `[wait]`/`[navigate]` both fire.

This is also why `./burrito_out/desktop start` prints `No file named start` — it is trying to
*run* "start" as a script.

**How it stayed hidden for so long:** ex_tauri's sidecar output handler matched only
`CommandEvent::Stdout`, discarding `Stderr`, `Terminated` and `Error`. The sidecar therefore
died in complete silence. `main.rs` now handles all four, and it was the resulting
`[sidecar] TERMINATED code=Some(0)` — *code 0*, ruling out a crash — that finally identified it.

### Resolved: endpoint-level config now takes effect in the sidecar

This was previously recorded here as open, with a guess that `Phoenix.Endpoint` read its
configuration before `Application.start/2` could write it. That guess was wrong, and so was the
framing: there was never anything wrong with the endpoint configuration. The sidecar was running
a stale payload that did not contain `Desktop.Config` at all — see the payload-cache section
above. The asymmetry that made it look like a config-ordering problem (adapter keys landing,
endpoint keys not) had a duller explanation: the *adapter* settings were also being applied by
the `if desktop?` block in `runtime.exs`, which the old payload did contain, while the endpoint
settings existed only in the module it did not.

Measured on the packaged `.app` after the fix, at the ephemeral port the Tauri host assigned:

| measure                | before            | after                |
|------------------------|-------------------|----------------------|
| endpoint bind          | `0.0.0.0:4095`    | `127.0.0.1:59758`    |
| `GET /`                | 200               | 200                  |
| WebSocket upgrade      | 403               | **101**              |
| origin-check errors    | 1                 | 0                    |
| Postgres attempts      | 0                 | 0                    |

And end-to-end against the running bundle: `phx-connected`, 19 nodes present in the LiveView
stream with correct `dom_id`s (`10:6`, not `nodes-10:6`), and the tick advancing 2728 → 2745 →
2751 across samples — so diffs are genuinely streaming, not a static first render.

## Notes on the build, kept for reference

*The ERTS version.* Burrito asks the CDN for the build machine's OTP version, and this
machine runs 29.0.4, which is unbuilt (404 on macOS and both Linux arches). `mix.exs` now pins
`custom_erts` per target to **29.0.3**, verified 200 on all three. No toolchain change was needed
and none is wanted: `custom_erts` accepts a URL, 29.0.3 is the same OTP major/minor so the compiled
BEAM is compatible, and downgrading would break a working environment — Elixir 1.20.2 here is
compiled against OTP 29, and brew's `erlang@28` is 28.5.0.4, which is not even a CDN version.

An earlier note in this document recommended pinning to **28.4.2** on the grounds that it was the
only version with ERTS for all three targets. That was wrong — it came from a probe that tested
29.0.4 on Linux but never tested 29.0.3 there. 29.0.3 is available on all three, so this is one
patch back rather than a major downgrade. Re-probe before a release; once the CDN builds 29.0.4 the
`custom_erts` entries can be dropped and Burrito's default becomes correct again.

`mix ex_tauri.dev` is unaffected by all of this and works independently.

**Consequence of wiring `&Burrito.wrap/1` into the release steps:** plain `mix release desktop` now
requires Zig too. That is the tradeoff for `mix ex_tauri.build` working; the asset-build step was
verified before Burrito was wired in, by deleting `priv/static/assets` and confirming the assembled
release contained zero asset files without the step and both files with it.

**Asset building in the desktop release — RESOLVED.** Recorded here because the reasoning is worth
keeping. `priv/static/assets/{css/app.css,js/app.js}` are gitignored (tailwind/esbuild output), and
the release's `:assemble` step only *copies* `priv/static`. So a release assembled on a clean
checkout would have shipped with no CSS and no JS — the LiveView would connect and function while
rendering completely unstyled. It worked locally only because those files happened to be sitting on
disk from an earlier `mix assets.build`.

Fixed by prepending a `build_assets/1` step: `steps: [&build_assets/1, :assemble]`. It calls the
existing `assets.build` alias rather than restating the tailwind/esbuild invocations, so there is
one definition to maintain. Deliberately *not* `assets.deploy` — that minifies (no benefit for
assets served over localhost to a webview, and unminified is easier to debug) and runs
`phx.digest`, whose `cache_manifest.json` nothing reads, since `config/prod.exs` omits
`cache_static_manifest` on purpose.

Verified end to end, and the verification did not require Burrito: the `desktop` release has no
`&Burrito.wrap/1` step, so `MIX_ENV=prod mix release desktop` assembles on its own. Deleting
`priv/static/assets` entirely and assembling produced both files inside
`_build/prod/rel/desktop/lib/armchair_metropolist-0.1.0/priv/static/assets/`. Mutation-checked:
with the step removed and the directory deleted, the assembled release contains only the three
tracked source assets and **zero** asset files.

Incidental finding while checking this: `app.css` rebuilds byte-identically but **`app.js` does
not** — esbuild output differs between runs. That is a second, independent reason not to track
these: they would produce a spurious diff on every build.

**Desktop release env staleness.** `main.rs` is generated by `mix ex_tauri.install` and has been
hand-edited to inject `ARMCHAIR_DESKTOP=1` (the marker every desktop config override keys off).
The `sidecar_env` config key exists to restore that on regeneration, but it is only read at
install time. **If the installer is ever re-run, verify the injection survived** — without it a
release silently reverts to the server defaults (Postgres, `LogNotifier`, no bounded drain). It
fails loudly on missing `DATABASE_URL` rather than losing data.

## Worth doing — all resolved, verified 2026-08-03

Every item this section listed has since been done. Checked individually rather than assumed, because
a standing record that still says "todo" for finished work misleads exactly the reader it is for:

* **Merge the two contract modules** — `snapshot_repository_ordering_contract.ex` no longer exists;
  its ordering cases live in `snapshot_repository_contract.ex`.
* **Delete unused generated components** — `input/1`, `header/1`, `table/1` and `list/1` are gone from
  `CoreComponents`, which now reports 100% coverage rather than the 16.67% that capped the gate.
* **Add `UseCases.SummarizeCity`** — `lib/armchair_metropolist/use_cases/summarize_city.ex`, at 100%.
* **Strip the Phoenix scaffolding branding** — no references remain in `layouts.ex` or
  `root.html.heex`.
* **Add a formatting gate** — `"format --check-formatted"` is in the `check:` alias in `mix.exs`.
  (This entry used to say it *heads* the alias and cite `mix.exs:601`. Both were wrong by 2026-08-03:
  `&check_versions/1` heads it, and the line had moved to 669. Line numbers in this document go stale
  silently — cite the symbol, not the line.)
* **`dev_routes` and the empty `seeds.exs`** — both removed.

The coverage figure in this document's header is also stale: the suite is now 236 tests (5 properties,
231 tests) at 94.86%.

* **Flatpak bundle — done 2026-08-04.** Every Release now carries a `.flatpak`, built in the
  `desktop` job by repackaging the `.deb` against `org.gnome.Platform//50`. It exists for the glibc
  floor: the `.deb` declares `libc6 (>= 2.39)` and so will not install on Debian 13 or older, while
  the Flatpak brings its own userspace. Verified by *running* it —
  `scripts/verify-flatpak.sh` starts the sidecar inside the sandbox and asserts Phoenix's boot
  banner, which no file-existence check could do, because a glibc mismatch leaves `flatpak-builder`
  exiting 0. Not on Flathub, so side-loaded and no auto-updates. Spec:
  `specs/2026-08-04-flatpak-bundle-design.md`.

  **Broken on any machine running xdg-desktop-portal, and fixed 2026-08-05.** Reported from AerynOS:
  the app installed, the sidecar booted, and the window contained only

  ```
  GDBus.Error:org.freedesktop.portal.Error.NotAllowed: This call is not available inside the sandbox
  ```

  The manifest's "no `--share=network`, deliberately" argument is correct about *packets* — loopback
  lives inside the private namespace, so nothing needs to leave — and that is exactly what made it
  wrong. Withholding the permission also makes xdg-desktop-portal refuse `ProxyResolver.Lookup`
  (guarded by `if (!xdp_app_info_has_network (app_info))`), and libsoup inside `WebKitNetworkProcess`
  asks GProxyResolver about **every** URI, loopback included. The load failed before a packet was sent
  and WebKit rendered the `GError` as the page, which is why it appeared in the window and in no log.

  Fixed with `--env=GIO_USE_PROXY_RESOLVER=dummy`, **not** `--share=network`: GLib already intends
  `direct://` for a network-less sandbox, it just puts that fallback after the call that errors, so the
  fix is to stop asking rather than to open the sandbox. Full derivation, including why the network
  monitor is unaffected and why CI structurally cannot reproduce it, in
  `specs/2026-08-04-flatpak-bundle-design.md` §6.

  **The generalisable lesson: a permission you do not need can still be load-bearing, because the check
  sits in front of a *question* your libraries ask rather than an action you take.** When justifying a
  sandbox decision with "the app does not need X", check what its dependencies *query* about X.

  Two traps found on the way, both worth knowing before touching this. `flatpak-builder` strips
  binaries with `eu-strip`, from `elfutils`, which it only *recommends* — so
  `--no-install-recommends` breaks the build after the module is already assembled. And do not
  manage a background process across the sandbox boundary: `flatpak run` will not return while
  anything lives inside, `kill` reaches Burrito's launcher rather than the `beam.smp` it spawned,
  and `timeout` without `--kill-after` sends SIGTERM and then waits forever. Two CI jobs hung before
  that was rewritten to run the sidecar in the foreground under its own `timeout`.

* **Tag-driven GitHub Releases — done 2026-08-03.** A `v*` tag now cuts a Release carrying the x86_64
  `.deb` and both sidecars, with the tag checked against all four declared versions before anything
  publishes, and `mix version.set X.Y.Z` to move those four together. This closes the payload-cache
  bug for anything anyone installs: distinct releases now carry distinct versions, and `main` no
  longer uploads a `.deb` at all. It stays open for the per-merge *sidecar* artifacts, which are
  still uploaded on every push and are still the same Burrito binary — deliberately, since they are
  the only way to test an unreleased merge. Spec:
  `specs/2026-08-03-tag-driven-releases-design.md`.

## Known limitations, accepted

**`SnapshotVocabulary` is a hand-maintained list.** Both adapters decode with
`:erlang.binary_to_term(payload, [:safe])`, which refuses to *create* atoms — and a saved city is
made of them. The vocabulary module loads the entity modules first so their atoms are interned.
The cold-VM regression test auto-covers new node types (it derives them from `Node.types/0`), but
its maximal city is hand-built from the two known structs, so **a third persisted struct would
slip past both the vocabulary and its test.** Guarded only by comments at each entity's
`defstruct`. See `SnapshotVocabulary`'s moduledoc.

A trap for whoever maintains it: the seven node-type atoms are **not** in either module's `AtU8`
atom chunk — they live in the compressed `LitT` literals chunk of `node.ex`'s `@capacity_table`.
A `:beam_lib` atom-chunk audit therefore reports a *false* coverage gap. Module load interns
literals, which is why `Code.ensure_loaded!` is the right mechanism.

**Resolved by the per-visitor-simulations branch (2026-08-03).** `snapshot_store.ex` no longer orders
by anything — the 2026-08-03 migration made `city_id` the primary key, one row per city, so `load/1`
is a plain `Repo.get/2` and there is no tie to break. The "nothing prunes `city_snapshots`" half is
also resolved: `SnapshotReaper` now deletes any city untouched for `:snapshot_retention_days` (90 by
default).

**`:snapshot_dir` has no default.** Set only in the desktop branch of `runtime.exs`. Configuring
`FileSnapshotStore` anywhere else yields `Path.join(nil, …)` → `FunctionClauseError` rather than a
clear configuration error.

**`config/runtime.exs` sets `http: [port: PORT || 4000]` for every environment**, deep-merging over
`config/test.exs`'s `4002`. Inert while `server: false`, but every `MIX_TEST_PARTITION` would share
port 4000 if the server were ever enabled in test. Generator-inherited.

**Resolved by the per-visitor-simulations branch (2026-08-03).** Both halves of the item this
replaces are now false. `simulator_live_test.exs`'s "updates *only* the affected node" was rewritten
on this branch to place two nodes and compare the untouched one, so "only" is now an actual claim the
test can fail. `simulation_calculator_test.exs`'s "includes a node whose status flips at unchanged
rounded health" does call `Calc.advance_tick/1` and asserts on its result — also no longer the gap
this entry described, though unrelated to this branch's own changes.

## A note on test design, learned the hard way

Repeatedly during this build, a requirement shipped with a test that **could not fail**. Every one
passed review by reading and was caught only by mutation — deliberately breaking the code and
checking whether anything noticed. The instances are worth knowing because they rhyme:

- An arithmetically impossible fixture: `assert round(87.3) == round(87.8)` (they are 87 and 88).
- A vacuous comparison: `assert avg_health == 0.0` passes for integer `0`, since `0 == 0.0` is true.
- A tautology: `assert f(x) == f(x)`, which no deterministic function can fail.
- A `refute` against a string the page never rendered — this one concealed **three Critical
  defects** behind a green suite, because node removal was entirely broken while
  `refute html =~ ~s{id="6:6"}` passed on a page whose ids were all `"nodes-6:6"`.
- A permutation "property": permuting map insertion order and asserting equal output asserts an
  Erlang invariant, not anything about the code — maps with equal key sets are the same term with
  the same iteration order.
- An assertion satisfied by pre-existing state: `assert table_exists?("city_snapshots")` after
  `Release.migrate/0` passed with `migrate/0` gutted entirely, because the test database was already
  migrated. Fixed by starting that test from a rolled-back database, so the claim and the
  precondition are not the same thing. (Found 2026-07-31, after this list was first written — the
  pattern is still live.)

Two rules came out of it, both now applied throughout the suite:

1. **Never write a `refute` without first asserting the positive case.** A refutation against
   something that never occurs is always true.
2. **A test you have not seen fail is not yet a test.** Before trusting one, break the code it
   covers and confirm it goes red.
