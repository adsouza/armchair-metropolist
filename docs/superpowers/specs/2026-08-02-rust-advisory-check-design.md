# A systematic advisory check for the Rust code — design

**Date:** 2026-08-02
**Status:** approved, not yet implemented

## 1. Problem

`mix check` scans the Elixir side for known-vulnerable dependencies (`deps.audit` against
mirego/elixir-security-advisories) and for insecure patterns (`sobelow`). The Rust side has
nothing. `src-tauri/Cargo.lock` pulls **493 crates** — the great majority transitively, through
Tauri — and no gate in this repository has ever looked at them.

That gap is asymmetric with the risk. The desktop target is a **redistributed binary**: the Linux
Burrito builds are uploaded as CI artefacts and the macOS bundle is what a user installs. A
vulnerable crate there ships to a machine, whereas the Elixir side at least sits behind a server
we control.

## 2. Measured starting position

Run against the real lockfile on 2026-08-02, 1186 advisories loaded, 493 crate dependencies:

| invocation | exit | what fires |
|---|---|---|
| `cargo audit` (default) | **0** | nothing |
| `--deny unsound` | 2 | RUSTSEC-2024-0429 |
| `--deny warnings` | 2 | all 17 findings |
| `--deny unsound --ignore RUSTSEC-2024-0429` | **0** | — |

Those exit codes are from the **CLI flags**. The same denial expressed in `audit.toml` (§6) exits
**1** rather than 2. Both are non-zero and both fail a CI step, so nothing in this design depends
on the difference — but a script that tests for a specific code would be wrong, and §8's figures
are the config ones for that reason.

**There are zero vulnerabilities.** All 17 findings are informational: 16 `unmaintained` and one
`unsound`. Of the 16, ten are the gtk-rs GTK3 bindings (`atk`, `atk-sys`, `gdk`, `gdk-sys`,
`gdkwayland-sys`, `gdkx11`, `gdkx11-sys`, `gtk`, `gtk-sys`, `gtk3-macros`), five are `unic-*`, and
one is `proc-macro-error`.

This matters because it inverts an assumption the work started from — that RUSTSEC-2024-0429 would
have to be ignored. At the default deny level it needs no ignore entry, because warnings do not
fail the run. It becomes something to ignore only once we deliberately raise the bar, which §3
argues we should.

## 3. What should redden the build

**Vulnerabilities and unsoundness. Not `unmaintained`.**

Blocking on vulnerabilities is the same stance `mix.exs` already takes for `deps.audit`, whose
comment says an advisory landing with no change to this repository turning the build red "is the
point of it". Extending to `unsound` costs one ignore entry today and buys detection of every
*future* soundness bug in 493 crates — worth it in a binary we redistribute, where a soundness bug
is a crash or worse on someone else's machine.

`unmaintained` is excluded deliberately. Ten of the sixteen are the GTK3 bindings that Tauri pins
us to (§4); no action available to this project clears them, so denying them would mean a
sixteen-entry allowlist that must be curated forever and that is dominated by findings we cannot
act on. An allowlist that large stops being read, which costs more than it buys.

## 4. Why RUSTSEC-2024-0429 is ignored

**The advisory.** `glib::VariantStrIter::impl_get` passed `&p` — an immutable reference to a NULL
`*mut libc::c_char` — to a C function that mutates the pointer in place. `CStr::from_ptr`
subsequently receives NULL. It affects `next`, `next_back`, `last`, `nth` and `nth_back` on the
`Iterator` and `DoubleEndedIterator` impls, and the symptom is a crash. Affected range is
`>=0.15.0, <0.20.0`; patched in `0.20.0`. The lockfile has **0.18.5**.

**Why it cannot be fixed here.** glib is not a dependency of this project. Nothing in
`src-tauri/Cargo.toml` names it. It arrives by exactly one route:

```
glib 0.18.5 → gtk 0.18.2 → { libappindicator→tray-icon, muda, tao→tauri-runtime-wry, webkit2gtk }
            → tauri 2.11.5
```

The fix lives in glib 0.20, which is the gtk-rs 0.20 generation. Tauri's Linux stack is still on
GTK3 — the same GTK3 bindings that account for ten of the `unmaintained` findings. There is no
version bump at any level this project controls that moves glib; only an upstream move off GTK3
does. The Dependabot alert for the same issue was dismissed on these grounds rather than fixed.

**It is Linux-only.** `cargo tree -i glib` finds it under `x86_64-unknown-linux-gnu` and finds
nothing under `aarch64-apple-darwin` or `x86_64-pc-windows-msvc`. It reaches the two Linux Burrito
builds and not the macOS bundle used for development.

**What is not claimed.** Whether Tauri reaches `VariantStrIter` on any path this application
exercises has not been verified. The justification is not "this cannot affect us" — it is that the
bug is crash-class, confined to a platform we do not develop on, unfixable from here, and that
carrying the exception is what buys a gate strict enough to catch the next one.

**The review trigger.** Drop the ignore when Tauri moves to a gtk-rs 0.20+ / webkit2gtk stack and
glib 0.18 leaves the lockfile. This is a known weakness of the design — see §7.

## 5. Shape

**A new job in `.github/workflows/ci.yml`,** `rust advisory`, on `ubuntu-24.04`:

1. `actions/checkout@v7`
2. `taiki-e/install-action@v2` with `tool: cargo-audit`
3. `cargo audit`, with `working-directory: src-tauri`

No Rust toolchain setup and no build step: cargo-audit reads `Cargo.lock`, which is tracked, and
never compiles the crate.

**Not `rustsec/audit-check`.** The official action declares `using: node20` at its latest tag
(v2.0.0). This workflow already carries one unavoidable node20 action, `mlugg/setup-zig`, together
with a comment explaining that the resulting deprecation warning cannot be silenced from here.
Adding a second, avoidable one is a poor trade. `taiki-e/install-action` is `composite` at
v2.85.7 — no Node runtime at all — and ships a prebuilt musl binary, so installation is seconds
rather than the ~60s a `cargo install cargo-audit --locked` takes.

**Not part of `mix check`.** Keeping it a separate CI job leaves the Elixir gate purely Elixir and
keeps a Rust toolchain off machines that only touch the web app. The cost is that the overall gate
now lives in two places; that is accepted deliberately, since `mix check`'s value is being one
command a laptop and a runner both run identically, and a Rust check nobody can run without cargo
would dilute it.

**Not a deploy gate.** `deploy` keeps `needs: [check]`. `ci.yml` already states that the desktop
binaries are a separate product and deliberately not a gate on deployability; the Rust crate is
the desktop wrapper, so it follows the same rule.

## 6. Configuration

A new `src-tauri/.cargo/audit.toml`, carrying the ignore with its reason:

```toml
[advisories]
# glib 0.18.5: unsoundness in VariantStrIter's Iterator/DoubleEndedIterator impls
# (a NULL CStr::from_ptr, crash-class). Fixed in glib 0.20, which is the gtk-rs 0.20
# generation. Nothing here depends on glib directly — it arrives via
# tauri → {tray-icon, muda, tao, webkit2gtk} → gtk 0.18.2 — so no bump available to
# this project moves it. Linux-only: absent from the darwin and windows trees.
# DROP THIS ENTRY when Tauri moves off GTK3 and glib leaves the lockfile.
ignore = ["RUSTSEC-2024-0429"]

[output]
deny = ["unsound"]
# Not optional. The [output] table has no serde defaults, so omitting `quiet`
# is a fatal parse error ("missing field `quiet`"), not a warning.
quiet = false
```

Configuration rather than CLI flags for two reasons: an ignore entry needs its reason beside it,
and a laptop run then behaves identically to CI without anyone having to remember the flags.

## 7. Known limitations, accepted

* **A stale ignore is silent.** cargo-audit does not report an ignore entry that no longer matches
  anything, so when glib finally leaves the lockfile nothing will say so. The config comment names
  the review trigger; that is mitigation, not a fix. Detecting it automatically would mean
  diffing the finding set against the ignore list, which is more machinery than one entry earns.
* **No scheduled run.** CI fires on push and pull request only, so an advisory published during a
  quiet week surfaces on the next commit rather than immediately. `mix deps.audit` has precisely
  the same gap, so this is consistent rather than a new hole. Adding a `schedule:` trigger later
  is additive and needs no rework.
* **The advisory database is fetched per run.** cargo-audit git-clones RustSec's database on each
  invocation, so the job wants network. No cache step: correctness of a security gate beats a few
  seconds, and a stale cached database is the failure mode worth avoiding.

## 8. Verification

The gate's own correctness is verified by mutation, not by observing a green run — a check that
passes because it is doing nothing looks identical to one that passes because it is satisfied.

* Replace `RUSTSEC-2024-0429` in the ignore list with a bogus id and confirm the run turns red.
  Already done during design: `exit 0` with the real id, `exit 1` with a bogus one, so the pass is
  carried by that entry and not by the deny level failing to engage.
* Confirm `deny = ["unsound"]` engages at all: with an empty ignore list the run must fail.
  Already done: `exit 1`.
* Confirm the committed config parses. A malformed `[output]` table is a fatal error, and the
  first draft of this config hit exactly that.
