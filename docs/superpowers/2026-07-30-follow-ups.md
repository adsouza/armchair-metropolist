# Follow-ups after the initial build

**Date:** 2026-07-30
**Branch:** `feat/city-simulator` (24 commits + final fix wave)
**State at hand-off:** 129 tests pass, `mix check` exits 0, coverage 71.98% gated at 70%.
`Domain`, `Domain.Services` and `UseCases` are at 100%.

Everything below was found during implementation, triaged, and deliberately deferred. Nothing
here blocks merge. The four must-fixes from the final whole-branch review (adapter I/O errors,
adapter `latest` divergence, the `:erlang` purity gap, and a property-suite tautology) were all
fixed and mutation-verified before hand-off.

## Needs a decision from you

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

## Blocked, with a known cause

**Burrito production build (`mix ex_tauri.build`).** One thing stands in the way now: **Zig is not
installed.** Two other blockers are resolved.

*Resolved — the ERTS version.* Burrito asks the CDN for the build machine's OTP version, and this
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

*Still blocking — Zig.* `ex_tauri`'s docs say Zig is "only needed if using Burrito for
cross-compilation". **That is wrong.** Burrito shells out to `zig build` unconditionally
(`lib/steps/build/pack_and_build.ex`), so Zig is required for *every* Burrito build including a
native one. Burrito 1.6 targets Zig 0.16. This is the third stale claim found in `ex_tauri`'s
documentation, after the OTP-28 ceiling and `sidecar_env`.

*Remaining wiring.* `&Burrito.wrap/1` is deliberately **not** in the release's `steps:`, so the
`burrito:` target config above is currently inert. Adding it is what enables
`mix ex_tauri.build` — `tauri.conf.json`'s `externalBin` expects `../burrito_out/desktop` — but it
also makes plain `mix release desktop` require Zig, which would break the no-extra-tooling
assembly path that makes the asset step verifiable. Add it together with Zig, not before.

`mix ex_tauri.dev` works today and is unaffected by all of this.

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

## Worth doing

**Merge the two contract modules.** The descending-tick ordering cases live in
`test/support/snapshot_repository_ordering_contract.ex` rather than
`snapshot_repository_contract.ex`, because the latter contains `use Boundary` and the fix wave was
barred from editing boundary files. **A new `SnapshotRepository` adapter must currently `use` both
modules or it will silently skip the ordering guarantees.** Mechanical merge.

**Delete unused generated components — this is what caps the coverage gate.** `CoreComponents`
sits at 16.67% and is the single largest reason the honest threshold is 70% rather than the spec's
90%. `input/1`, `header/1`, `table/1` and `list/1` are referenced nowhere. Removing ~250 lines of
unreferenced generated code would let the threshold rise substantially. Also unused:
`config :armchair_metropolist, dev_routes: true` (no reader — the router has no dev scope) and the
empty `priv/repo/seeds.exs` stub, still run by the `ecto.setup` alias.

**Add `UseCases.SummarizeCity`.** `CityEngine.snapshot/0` returns metrics whose `resources` map is
empty until the first tick, and whose counters lag a place/demolish by up to one tick. The cause
is structural and correct: `Infrastructure` is deliberately barred from `Domain.Services`, so the
engine cannot compute resource stats. A read-only use case is the designed fix — `UseCases` *may*
reach `Domain.Services`. `SimulatorLive` currently handles the empty case with a placeholder.

**Strip the Phoenix scaffolding branding.** `Layouts.app` still renders the Phoenix logo, a version
badge and Website/GitHub/Get Started links; `root.html.heex` titles the app
"· Phoenix Framework". This shows in the native desktop window.

**Add a formatting gate.** `mix format --check-formatted` fails on 8 files. `mix check` has no
format step, and the `precommit` alias runs `format` (which rewrites) rather than
`--check-formatted` (which fails), so drift ships silently.

## Known limitations, accepted

**`SnapshotVocabulary` is a hand-maintained list.** Both adapters decode with
`:erlang.binary_to_term(payload, [:safe])`, which refuses to *create* atoms — and a saved city is
made of them. The vocabulary module loads the entity modules first so their atoms are interned.
The cold-VM regression test auto-covers new node types (it derives them from `Node.types/0`), but
its maximal city is hand-built from the two known structs, so **a third persisted struct would
slip past both the vocabulary and its test.** Guarded only by comments at each entity's
`defstruct`. See `SnapshotVocabulary`'s moduledoc.

A trap for whoever maintains it: the seven node-type atoms are **not** in either module's `AtU8`
atom chunk — they live in the compressed `LitT` literals chunk of `node.ex`'s `@production_table`.
A `:beam_lib` atom-chunk audit therefore reports a *false* coverage gap. Module load interns
literals, which is why `Code.ensure_loaded!` is the right mechanism.

**`snapshot_store.ex` has no tiebreaker.** `order_by: [desc: s.tick]` with no secondary key. An
engine that crashes and replays can write two rows at the same tick with different content, and
which one wins is unspecified. Also, nothing prunes `city_snapshots` — roughly 1,700 rows/day at
one tick per second.

**`:snapshot_dir` has no default.** Set only in the desktop branch of `runtime.exs`. Configuring
`FileSnapshotStore` anywhere else yields `Path.join(nil, …)` → `FunctionClauseError` rather than a
clear configuration error.

**`config/runtime.exs` sets `http: [port: PORT || 4000]` for every environment**, deep-merging over
`config/test.exs`'s `4002`. Inert while `server: false`, but every `MIX_TEST_PARTITION` would share
port 4000 if the server were ever enabled in test. Generator-inherited.

**Two test titles promise more than their bodies check.** `simulator_live_test.exs`'s "updates
*only* the affected node" asserts only that the changed node appears; and
`simulation_calculator_test.exs`'s "includes a node whose status flips at unchanged rounded health"
never calls `advance_tick/1` — it duplicates a `node_test.exs` case, leaving that delta row covered
only by the property test.

## A note on test design, learned the hard way

Eight times during this build, a requirement shipped with a test that **could not fail**. Every one
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

Two rules came out of it, both now applied throughout the suite:

1. **Never write a `refute` without first asserting the positive case.** A refutation against
   something that never occurs is always true.
2. **A test you have not seen fail is not yet a test.** Before trusting one, break the code it
   covers and confirm it goes red.
