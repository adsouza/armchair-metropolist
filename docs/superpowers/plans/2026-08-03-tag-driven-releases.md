# Tag-Driven GitHub Releases Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a `v*` git tag cut a permanent GitHub Release carrying the x86_64 `.deb` and both Burrito sidecars, with the tag checked against the version the repository declares.

**Architecture:** `mix.exs` stays the source of truth for the version. The existing `check_versions/1` guard gains a *conditional* fifth site — the git tag — present only when CI exports `RELEASE_TAG`. A new `mix version.set` task moves all four declarations together. `ci.yml` gains a tag trigger and a `release` job; no second workflow file, so the `desktop` job is never duplicated.

**Tech Stack:** Elixir 1.20.2 / OTP 29.0.3, Mix aliases and tasks, GitHub Actions, `gh` CLI, Tauri 2 + Burrito.

**Spec:** `docs/superpowers/specs/2026-08-03-tag-driven-releases-design.md`. Read it before Task 1; every design decision below is justified there and this plan does not repeat the reasoning.

## Global Constraints

- **Elixir 1.20.2 / OTP 29.0.3** on the desktop and release paths; `check` also runs a floor of Elixir 1.19.3 / OTP 27.3.
- **`check_versions/1` runs first in the `check` alias and must stay dependency-free.** It executes before `compile`, so deps may not be on the code path. Use OTP's `:json`, never Jason. This is why `decode_json/1` exists.
- **`mix check` is also the pre-push git hook** (`.githooks/`, installed by `mix setup`). Anything that makes it fail without a tag breaks every push.
- **Current version is `0.1.0`** in all four sites. Do not bump it during this work — `v0.1.0` is reserved as the first real release and doubles as the positive test (spec §9 row 8).
- **`Cargo.lock` is never hand-edited.** Regenerate with `cd src-tauri && cargo update --offline -p armchair_metropolist`. `cargo metadata --offline` exits 101 and is the wrong tool.
- **Terminology:** "allowlist" / "denylist" only.
- **Verification is by mutation.** A check that passes because it is doing nothing looks identical to one that passes because it is satisfied. Every task below states the mutation that must turn it red.
- **Commit style:** imperative subject, body explaining *why*. End every commit message with `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.

---

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `mix.exs` | Modify (`check_versions/1` ~line 279, helpers below it) | Owns the version-site list, including the conditional tag site. Stays the single definition. |
| `lib/mix/tasks/version.set.ex` | Create | `mix version.set X.Y.Z`. Pure string transforms plus the file/shell wiring. First Mix task in this repo. |
| `test/mix/tasks/version_set_test.exs` | Create | Unit tests for the pure transforms. Must not touch the real `mix.exs`. |
| `.github/workflows/ci.yml` | Modify (triggers ~line 3, `check` job ~line 26, `desktop` env ~line 129, `.deb` upload ~line 281, new job at end) | Tag trigger, `RELEASE_TAG` export, `BUNDLE` gate, tag-only `.deb` upload, the `release` job. |
| `README.md` | Modify | Installing a release; cutting a release. |
| `docs/superpowers/specs/2026-08-02-linux-desktop-bundle-design.md` | Modify (§10, §11, §12) | Correct claims this change falsifies. |
| `docs/superpowers/2026-07-30-follow-ups.md` | Modify | Standing record: release work intended → done. |

---

## Task 1: The conditional fifth version site

**Files:**
- Modify: `mix.exs` — `check_versions/1` (~line 279) and the private readers below it

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `ArmchairMetropolist.MixProject.version_sites/0`, public, returning `[{String.t(), String.t() | nil}]` — a list of `{label, version}` pairs, four entries plus a fifth when `RELEASE_TAG` names a valid tag. Task 2 calls this.

**Why `version_sites/0` must read `mix.exs` from disk:** `Mix.Project.config()[:version]` is cached when the project loads. Task 2 rewrites `mix.exs` and then re-runs this comparison **in the same process**, where the cached value would still be the old one — so the task would report success for a write it had not actually verified. Reading the file is what makes Task 2's self-check real.

- [ ] **Step 1: Read the current implementation**

Open `mix.exs` and read `check_versions/1` together with `tauri_conf_version/0`, `cargo_toml_version/0` and `cargo_lock_version/0`. Note two things you will change: the `sites` list, and the sentence **"All four must carry the same value."** in the mismatch message.

- [ ] **Step 2: Establish the baseline, so later red is meaningful**

```bash
mix check 2>&1 | head -5
```

Expected: among the first lines, `[versions] 0.1.0`. If `mix check` is already failing, stop and fix that first — you cannot mutation-test against a red baseline.

- [ ] **Step 3: Replace the `sites` list with a call to a new public function**

In `check_versions/1`, replace the literal list:

```elixir
  defp check_versions(_args) do
    sites = version_sites()
```

Leave the rest of `check_versions/1` untouched for now.

- [ ] **Step 4: Add `version_sites/0` and the tag reader**

Add these directly above `tauri_conf_version/0`:

```elixir
  @doc false
  # Public so `mix version.set` can re-derive this list after writing, instead of
  # keeping a second copy of these readers. A hand-maintained mirror of a list the
  # code already owns is precisely the thing that drifts, and the drift is silent.
  # `ArmchairMetropolist.MixProject` is loaded for the whole of any Mix invocation,
  # so the task can call this with no compile-order problem.
  def version_sites do
    [
      {"mix.exs", mix_exs_version()},
      {"src-tauri/tauri.conf.json", tauri_conf_version()},
      {"src-tauri/Cargo.toml", cargo_toml_version()},
      {"src-tauri/Cargo.lock", cargo_lock_version()}
    ] ++ release_tag_site()
  end

  # From disk, not from Mix.Project.config()[:version], which is cached at load
  # time. `mix version.set` rewrites this file and re-runs the comparison in the
  # same process; against the cached value it would be grading its own homework
  # with the answer sheet from before the edit.
  defp mix_exs_version do
    with {:ok, body} <- File.read("mix.exs"),
         [_, version] <- Regex.run(~r/^\s*version:\s*"([^"]+)"/m, body) do
      version
    else
      _ -> nil
    end
  end

  # The git tag, and only when a release workflow put one in the environment.
  #
  #   unset or ""        -> []            four sites: exactly today's behaviour.
  #   "v1.2.3"           -> [{_, "1.2.3"}] compared with the rest; disagreement fatal.
  #   anything else      -> [{_, nil}]     trips the nil-guard in check_versions/1.
  #
  # Returning [] for a *malformed* tag would skip the check in silence — the exact
  # "a version check that silently reads nothing passes forever" failure the
  # nil-guard exists to prevent.
  #
  # "" is the deliberate exception and is not a nicety. GitHub Actions cannot
  # conditionally omit an environment variable, so a job-level
  # `RELEASE_TAG: ${{ github.ref_type == 'tag' && github.ref_name || '' }}`
  # evaluates to "" on every branch push. Treating "" as malformed would make this
  # guard fatal on every push to main and every pull request — including the
  # pre-push hook — and it would be ripped out within a day. "" means absent. The
  # shapes a *human* gets wrong ("v0.2", a full "refs/tags/..." ref) all still trip it.
  defp release_tag_site do
    case System.get_env("RELEASE_TAG") do
      nil -> []
      "" -> []
      tag -> [{"git tag #{tag}", tag_version(tag)}]
    end
  end

  # \A and \z rather than ^ and $: $ accepts a trailing newline, and a workflow
  # handing over "refs/tags/v1.2.3\n" is exactly the input this must reject.
  defp tag_version("v" <> rest) do
    if Regex.match?(~r/\A\d+\.\d+\.\d+\z/, rest), do: rest, else: nil
  end

  defp tag_version(_other), do: nil
```

- [ ] **Step 5: Fix the two sentences this falsifies**

In `check_versions/1`'s mismatch message, the line reading:

```
        All four must carry the same value. After editing src-tauri/Cargo.toml,
        regenerate the lock rather than editing it:

            cd src-tauri && cargo update --offline -p #{Mix.Project.config()[:app]}
```

becomes:

```
        Every site above must carry the same value. Rather than editing them by
        hand, move all four together:

            mix version.set X.Y.Z
```

"All four" is false once a fifth site exists, and the Cargo remediation is superseded by Task 2. If you are executing tasks out of order and Task 2 does not exist yet, still make this change — Task 2 is in the same plan and the message would otherwise need editing twice.

- [ ] **Step 6: Prove the unset case is unchanged**

```bash
mix check 2>&1 | head -5
```

Expected: `[versions] 0.1.0`, and the run proceeds exactly as in Step 2. This is the row that protects every laptop and every pull request.

- [ ] **Step 7: Prove the empty case is unchanged**

```bash
RELEASE_TAG= mix check 2>&1 | head -5
```

Expected: `[versions] 0.1.0`. This is what every push to `main` will send once Task 3 lands. If this is red, `main` is broken.

- [ ] **Step 8: Prove a matching tag passes**

```bash
RELEASE_TAG=v0.1.0 mix check 2>&1 | head -5
```

Expected: `[versions] 0.1.0`.

- [ ] **Step 9: Prove a mismatching tag fails**

```bash
RELEASE_TAG=v9.9.9 mix check 2>&1 | head -20
```

Expected: fails with "Version declarations disagree", listing **five** rows, the last being `git tag v9.9.9   9.9.9`.

- [ ] **Step 10: Prove a malformed tag fails via the nil-guard, not silently**

```bash
RELEASE_TAG=garbage mix check 2>&1 | head -20
RELEASE_TAG=refs/tags/v0.1.0 mix check 2>&1 | head -20
RELEASE_TAG=v0.2 mix check 2>&1 | head -20
```

Expected, for all three: fails with **"Could not read a version from git tag …"**, not with "declarations disagree". This is the single most important check in the task. A naive implementation returning `[]` for a malformed tag passes Step 9 and fails here — and would leave the guard disarmed for the likeliest real CI mistake, which is passing the full ref instead of the tag name.

- [ ] **Step 11: Mutation-verify all five sites, one at a time**

Bundle design §12 requires each site be mutated **separately** — its words are "four separate mutations, not one" — so that a passing check cannot conceal a site nobody reads. There are now five. For each of `mix.exs`, `src-tauri/tauri.conf.json`, `src-tauri/Cargo.toml`, `src-tauri/Cargo.lock`:

```bash
# Edit one file's version to 9.9.9, then:
RELEASE_TAG=v0.1.0 mix check 2>&1 | head -20   # must be RED, naming that file
git checkout -- <the file>                      # restore before the next mutation
```

The fifth site is Step 9, already done. Restore every file and confirm `mix check` is green again before committing — the red must be carried by the mutation, not by a check you broke outright.

- [ ] **Step 12: Commit**

```bash
git add mix.exs
git commit -m "$(cat <<'EOF'
feat: check the release tag against the declared version

check_versions/1 gains a fifth site: the git tag, present only when a release
workflow exports RELEASE_TAG. Conditional because this function also runs in
the PR gate and the pre-push hook, where no tag exists — an unconditional site
would read nil there and the nil-guard is deliberately fatal.

A set-but-malformed tag yields a nil site rather than no site, so it trips that
guard instead of being skipped in silence. The empty string is the one
exception and means absent: GitHub Actions cannot conditionally omit an env
var, so "" is how every branch push reports "no tag".

version_sites/0 is public and reads mix.exs from disk rather than from the
load-time-cached Mix.Project.config, so `mix version.set` can re-derive it
after writing and actually see its own edits.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: `mix version.set`

**Files:**
- Create: `lib/mix/tasks/version.set.ex`
- Test: `test/mix/tasks/version_set_test.exs`

**Interfaces:**
- Consumes: `ArmchairMetropolist.MixProject.version_sites/0` from Task 1.
- Produces: `Mix.Tasks.Version.Set.bump_mix_exs/2`, `bump_tauri_conf/2`, `bump_cargo_toml/2` — each `(binary(), binary()) :: binary()`, taking file content and a version and returning new content. Public so they can be unit-tested without touching real files. No later task depends on them.

**Design note:** the three transforms are pure string→string so the tests never rewrite the real `mix.exs`. Only `run/1` touches disk.

- [ ] **Step 1: Write the failing tests**

Create `test/mix/tasks/version_set_test.exs`:

```elixir
defmodule Mix.Tasks.Version.SetTest do
  @moduledoc """
  The transforms are pure so these tests never touch the real mix.exs — a test
  that rewrote the project's own version would corrupt the tree it runs in.

  Each "leaves other versions alone" case is the one that matters: these files
  all contain several version-shaped strings, and a greedy pattern silently
  rewrites the wrong one.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Version.Set

  describe "bump_mix_exs/2" do
    test "rewrites the project version" do
      before = ~s|  def project do\n    [\n      app: :armchair_metropolist,\n      version: "0.1.0",\n      elixir: "~> 1.19"\n    ]\n  end|

      assert Set.bump_mix_exs(before, "0.2.0") =~ ~s|version: "0.2.0"|
    end

    test "leaves the elixir requirement alone" do
      before = ~s|      version: "0.1.0",\n      elixir: "~> 1.19"|
      after_ = Set.bump_mix_exs(before, "0.2.0")

      assert after_ =~ ~s|elixir: "~> 1.19"|
      refute after_ =~ ~s|version: "0.1.0"|
    end
  end

  describe "bump_tauri_conf/2" do
    test "rewrites the top-level version" do
      before = ~s|{\n  "productName": "Armchair Metropolist",\n  "version": "0.1.0",\n  "identifier": "com.example.app"\n}|

      assert Set.bump_tauri_conf(before, "0.2.0") =~ ~s|"version": "0.2.0"|
    end

    test "leaves a nested version alone" do
      before = ~s|{\n  "version": "0.1.0",\n  "bundle": { "deb": { "depends": ["libc6 (>= 2.39)"] } }\n}|
      after_ = Set.bump_tauri_conf(before, "0.2.0")

      assert after_ =~ ~s|"version": "0.2.0"|
      assert after_ =~ ~s|libc6 (>= 2.39)|
    end
  end

  describe "bump_cargo_toml/2" do
    test "rewrites the [package] version" do
      before = ~s|[package]\nname = "armchair_metropolist"\nversion = "0.1.0"\n\n[dependencies]\ntauri = { version = "2.0" }|

      assert Set.bump_cargo_toml(before, "0.2.0") =~ ~s|version = "0.2.0"|
    end

    test "leaves a dependency version alone" do
      before = ~s|[package]\nversion = "0.1.0"\n\n[dependencies]\ntauri = { version = "2.0" }|
      after_ = Set.bump_cargo_toml(before, "0.2.0")

      assert after_ =~ ~s|tauri = { version = "2.0" }|
      refute after_ =~ ~s|version = "0.1.0"|
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
mix test test/mix/tasks/version_set_test.exs
```

Expected: FAIL — `Mix.Tasks.Version.Set` is undefined.

- [ ] **Step 3: Write the task**

Create `lib/mix/tasks/version.set.ex`:

```elixir
defmodule Mix.Tasks.Version.Set do
  @shortdoc "Moves every version declaration to X.Y.Z"

  @moduledoc """
  Sets the project version across all four places that declare it.

      mix version.set 0.2.0

  Four files must agree or `mix check` refuses to build, and one of them is a
  lock file that must be *regenerated* rather than edited. The incantation for
  that is not the obvious one: `cargo metadata --offline` exits 101, and the
  form that works is `cargo update --offline -p armchair_metropolist`.

  `check_versions/1` in `mix.exs` already *catches* drift between these files.
  This task *prevents* it, and then re-runs that same comparison rather than
  trusting its own writes.
  """

  use Mix.Task

  # This repository compiles with the `boundary` checker, and `{:mix, :runtime}`
  # is a checked application, so every module under lib/ must belong to a
  # boundary. A Mix task belongs to no layer of the application — it is
  # tooling — which is the case `top_level?: true` exists for, exactly as
  # `ArmchairMetropolist.Release` does it.
  use Boundary, top_level?: true, deps: [Mix]

  @version_pattern ~r/\A\d+\.\d+\.\d+\z/

  @impl Mix.Task
  def run([version]) do
    unless Regex.match?(@version_pattern, version) do
      Mix.raise("""
      Not a version: #{inspect(version)}

      Expected MAJOR.MINOR.PATCH, digits only — for example 0.2.0. The git tag
      that releases it will be this value prefixed with "v".
      """)
    end

    update!("mix.exs", &bump_mix_exs(&1, version))
    update!("src-tauri/tauri.conf.json", &bump_tauri_conf(&1, version))
    update!("src-tauri/Cargo.toml", &bump_cargo_toml(&1, version))
    regenerate_lock!()
    verify!()
  end

  def run(_args) do
    Mix.raise("Usage: mix version.set X.Y.Z")
  end

  @doc "Rewrites the `version:` entry in a mix.exs body."
  @spec bump_mix_exs(binary(), binary()) :: binary()
  def bump_mix_exs(body, version) do
    String.replace(body, ~r/^(\s*version:\s*)"[^"]+"/m, ~s|\\1"#{version}"|, global: false)
  end

  @doc "Rewrites the top-level `\"version\"` entry in a tauri.conf.json body."
  @spec bump_tauri_conf(binary(), binary()) :: binary()
  def bump_tauri_conf(body, version) do
    String.replace(body, ~r/^(\s*"version":\s*)"[^"]+"/m, ~s|\\1"#{version}"|, global: false)
  end

  @doc "Rewrites the `version` entry of Cargo.toml's `[package]` table."
  @spec bump_cargo_toml(binary(), binary()) :: binary()
  def bump_cargo_toml(body, version) do
    String.replace(body, ~r/^(version\s*=\s*)"[^"]+"/m, ~s|\\1"#{version}"|, global: false)
  end

  defp update!(path, fun) do
    body = File.read!(path)
    new_body = fun.(body)

    if new_body == body do
      Mix.raise("#{path} was not changed — its version pattern did not match.")
    end

    File.write!(path, new_body)
    Mix.shell().info("  updated #{path}")
  end

  # `cargo update`, not a hand edit: the lock records a checksum-bearing graph and
  # editing it by hand desynchronises it from Cargo.toml in ways cargo only
  # complains about later. `--offline` because this must work without network and
  # the package is local.
  defp regenerate_lock! do
    case System.cmd("cargo", ["update", "--offline", "-p", "armchair_metropolist"],
           cd: "src-tauri",
           stderr_to_stdout: true
         ) do
      {_out, 0} -> Mix.shell().info("  updated src-tauri/Cargo.lock")
      {out, status} -> Mix.raise("cargo update failed (#{status}):\n\n#{out}")
    end
  end

  # Re-derive rather than assume. This calls the same reader that guards the
  # build, so a write that looked fine but landed in the wrong place is caught
  # here rather than by CI. `version_sites/0` reads mix.exs from disk precisely
  # so that this sees the edit made moments ago.
  defp verify! do
    sites = ArmchairMetropolist.MixProject.version_sites()

    case sites |> Enum.map(&elem(&1, 1)) |> Enum.uniq() do
      [agreed] when is_binary(agreed) ->
        Mix.shell().info("\nAll #{length(sites)} sites now declare #{agreed}.")

      _ ->
        Mix.raise("""
        Wrote the files but they still disagree:

        #{Enum.map_join(sites, "\n", fn {f, v} -> "  #{String.pad_trailing(f, 28)} #{inspect(v)}" end)}
        """)
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
mix test test/mix/tasks/version_set_test.exs
```

Expected: PASS, 6 tests.

- [ ] **Step 5: Verify the boundary checker accepts the new module**

```bash
mix compile --force --warnings-as-errors 2>&1 | tail -20
```

Expected: no warnings, no boundary errors. **If boundary complains** about the call to `ArmchairMetropolist.MixProject` (which lives in `mix.exs`, outside the checked tree), replace the boundary declaration with:

```elixir
  # `ignore?: true` rather than a dep list: the only cross-module call here is to
  # ArmchairMetropolist.MixProject, which lives in mix.exs and is therefore not a
  # module boundary can classify. Nothing in the application calls this task.
  use Boundary, ignore?: true
```

Re-run the command and confirm it is clean. Record which variant you used in the commit body.

- [ ] **Step 6: Verify the task rejects a bad argument before touching anything**

```bash
mix version.set 0.2 ; echo "exit: $?"
git status --short
```

Expected: raises "Not a version", non-zero exit, and `git status` shows **no modified files**. Validating before the first write is what makes a failed run safe to retry.

- [ ] **Step 7: Verify a real bump touches exactly four files, then undo it**

```bash
mix version.set 0.2.0
git diff --stat
```

Expected: exactly four files changed — `mix.exs`, `src-tauri/tauri.conf.json`, `src-tauri/Cargo.toml`, `src-tauri/Cargo.lock` — and the task prints `All 4 sites now declare 0.2.0.`

Confirm the guard agrees, then restore:

```bash
RELEASE_TAG=v0.2.0 mix check 2>&1 | head -5    # expect [versions] 0.2.0
git checkout -- mix.exs src-tauri/tauri.conf.json src-tauri/Cargo.toml src-tauri/Cargo.lock
mix check 2>&1 | head -5                        # expect [versions] 0.1.0
```

The tree must end at `0.1.0`. `v0.1.0` is reserved as the first real release.

- [ ] **Step 8: Commit**

```bash
git add lib/mix/tasks/version.set.ex test/mix/tasks/version_set_test.exs
git commit -m "$(cat <<'EOF'
feat: move every version declaration with one command

Four files must agree or the build refuses, and one is a lock file that has to
be regenerated rather than edited — with an incantation that is not the obvious
one, since `cargo metadata --offline` exits 101.

The three rewrites are pure string transforms so they can be tested without the
suite rewriting the project's own mix.exs. Each has a paired test asserting the
*other* version-shaped strings in that file survive, which is the failure a
greedy pattern actually produces.

After writing, the task re-derives version_sites/0 rather than trusting itself:
the guard that gates the build is the same code that confirms the bump landed.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Trigger on tags, and stop uploading `.deb`s from main

**Files:**
- Modify: `.github/workflows/ci.yml` — `on:` (~line 3), `check` job (~line 26), `desktop` `env:` (~line 129), `.deb` upload (~line 281)

**Interfaces:**
- Consumes: `RELEASE_TAG` handling from Task 1.
- Produces: artifacts `desktop-x86_64-unknown-linux-gnu`, `desktop-aarch64-unknown-linux-gnu` (both, every run) and `desktop-bundle-x86_64-unknown-linux-gnu` (tags only). Task 4 downloads these three names.

- [ ] **Step 1: Add the tag trigger**

Replace the `on:` block at the top of `.github/workflows/ci.yml`:

```yaml
on:
  push:
    branches: [main]
    # `v*` rather than a semver glob. GitHub's syntax page says filter patterns
    # accept `*`, `**`, `+`, `?` and `!`, but the cheat sheet defining whether `+`
    # means "one or more", whether `[0-9]` classes work, and whether `.` stays
    # literal could not be confirmed — and a trigger that silently never fires is
    # the worst failure available here. So the glob stays coarse and deliberately
    # over-matches; the precise check is `release_tag_site/0` in mix.exs, which is
    # testable. A `v`-prefixed non-release tag therefore fails `check` loudly,
    # which is the right outcome for a tag that looks like a release and is not.
    tags: ['v*']
  pull_request:
```

The repository's existing non-version tag, `backup-pre-squash`, does not start with `v` and is excluded.

- [ ] **Step 2: Export the tag to the `check` job**

Add a job-level `env:` to the `check` job, directly under `runs-on:`:

```yaml
    # Empty on every branch push — Actions cannot conditionally omit a variable,
    # and mix.exs reads "" as "no tag". On a tag this makes check_versions/1
    # compare the tag against all four declared versions, so a tag that
    # disagrees fails here and `release` (which needs this job) never runs.
    env:
      RELEASE_TAG: ${{ github.ref_type == 'tag' && github.ref_name || '' }}
```

- [ ] **Step 3: Extend the `BUNDLE` gate to tags**

In the `desktop` job's `env:`, replace the `BUNDLE:` line. Keep the long comment above it and append a sentence:

```yaml
      BUNDLE: ${{ github.event_name == 'push' && (github.ref == 'refs/heads/main' || github.ref_type == 'tag') && matrix.target == 'x86_64-unknown-linux-gnu' }}
```

Add to the end of that comment block:

```yaml
      # Tags bundle too, because a Release carries the .deb. Pushes to main still
      # build and verify it — that is what catches packaging breakage at merge
      # time rather than while cutting a release — but no longer upload it.
```

- [ ] **Step 4: Make the `.deb` upload tag-only**

Change the "Upload the Linux bundle" step's condition:

```yaml
      # Tag-only. On main the package is built, verified, and discarded: the
      # Release is the durable copy, and not publishing a .deb from main also
      # closes the route by which someone could install two *packages* carrying
      # the same version — the stale-Burrito-payload bug in the spec's §1.
      - name: Upload the Linux bundle
        if: env.BUNDLE == 'true' && github.ref_type == 'tag'
```

Leave the other four `if: env.BUNDLE == 'true'` steps (apt, CLI, build, verify) alone — those must still run on main.

- [ ] **Step 5: Lint the workflow**

```bash
actionlint .github/workflows/ci.yml && echo "actionlint clean"
```

Expected: clean. If `actionlint` is not installed, `brew install actionlint`.

- [ ] **Step 6: Verify the gate expressions by hand**

There is no local runner, so evaluate the four cases on paper and write them into the commit body. Confirm each against the YAML you just wrote:

| Event | `RELEASE_TAG` | `BUNDLE` (x86_64) | `.deb` uploaded? |
|---|---|---|---|
| pull request | `''` | `false` | no |
| push to `main` | `''` | `true` | **no** |
| push tag `v0.1.0` | `v0.1.0` | `true` | yes |
| push tag `v0.1.0`, aarch64 leg | `v0.1.0` | `false` | no |

Also confirm by reading that the `deploy` job's `if:` is still `github.event_name == 'push' && github.ref == 'refs/heads/main'` — a tag ref is not that string, so tags must never deploy to Gigalixir.

- [ ] **Step 7: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "$(cat <<'EOF'
ci: build on v* tags, and stop publishing .debs from main

Adds a tag trigger to the existing workflow rather than a second file, so the
desktop job is never duplicated — hand-maintained mirrors in this repository
have drifted three times in one branch.

`check` exports RELEASE_TAG, empty on branches, so the version guard compares
the tag against all four declarations before anything is published. BUNDLE now
covers tags as well as main; main keeps building and verifying the .deb so
packaging breakage still surfaces at merge time, but no longer uploads it.

The glob is `v*` rather than a semver pattern: the docs confirm `+` and `!` are
accepted but not their semantics, and a trigger that silently never fires is
worse than one that over-matches into a loud, explained failure.

deploy is unaffected: its condition tests refs/heads/main exactly, which no tag
ref satisfies.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: The `release` job

**Files:**
- Modify: `.github/workflows/ci.yml` — new job appended after `desktop`

**Interfaces:**
- Consumes: the three artifact names from Task 3.
- Produces: a GitHub Release at the pushed tag. Nothing depends on it.

- [ ] **Step 1: Determine the correct `download-artifact` major**

The repo pins `actions/upload-artifact@v7`. Upload and download majors are paired and must match; do not guess.

```bash
gh api repos/actions/download-artifact/releases --jq '.[0:5][] | .tag_name'
```

Pick the latest major that pairs with `upload-artifact@v7` — check the action's README at that tag if the pairing is not obvious. Use that tag below in place of `@vN`.

- [ ] **Step 2: Add the job**

Append after the `desktop` job, before `rust-advisory`:

```yaml
  # Publishes what `desktop` built to a permanent, public Release. Only reachable
  # from a v* tag, which the `on:` block above is what admits.
  release:
    name: release ${{ github.ref_name }}
    runs-on: ubuntu-24.04
    if: github.ref_type == 'tag'

    # `needs: [check]` is load-bearing, not tidiness: without it a tag whose tests
    # fail still publishes. It is also where the tag-vs-version guard runs, so a
    # mismatched tag stops here. `needs: [desktop]` waits for *both* matrix legs,
    # so a broken aarch64 sidecar blocks the Release rather than yielding a
    # partial one.
    needs: [check, desktop]

    # The workflow default is `contents: read`, which cannot create a Release —
    # `gh release create` would fail with 403. Raised for this job alone rather
    # than workflow-wide, so no other job gains write access to the repository.
    permissions:
      contents: write

    steps:
      - uses: actions/checkout@v7

      # No `name:`, so every artifact from this run lands under artifacts/<name>/.
      - uses: actions/download-artifact@vN
        with:
          path: artifacts

      # Fail before `gh` does, with a message that says which file is missing and
      # shows what actually arrived. A Release is public and permanent; a partial
      # one is worse than none.
      - name: Verify every asset arrived
        run: |
          set -eu
          DEB=$(find artifacts/desktop-bundle-x86_64-unknown-linux-gnu -name '*.deb' -type f | head -1)
          test -n "$DEB" || { echo "::error::no .deb in the bundle artifact"; find artifacts -type f; exit 1; }
          for T in x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu; do
            test -f "artifacts/desktop-$T/desktop_$T" \
              || { echo "::error::missing sidecar for $T"; find artifacts -type f; exit 1; }
          done
          echo "DEB=$DEB" >> "$GITHUB_ENV"
          ls -la "$DEB" artifacts/desktop-*/desktop_*

      # --generate-notes composes the body from commits since the previous tag.
      # This repository squash-merges, so every line is already a readable PR
      # title and the notes need no maintenance.
      - name: Create the Release
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          gh release create "${{ github.ref_name }}" \
            --title "${{ github.ref_name }}" \
            --generate-notes \
            "$DEB" \
            artifacts/desktop-x86_64-unknown-linux-gnu/desktop_x86_64-unknown-linux-gnu \
            artifacts/desktop-aarch64-unknown-linux-gnu/desktop_aarch64-unknown-linux-gnu
```

- [ ] **Step 3: Lint**

```bash
actionlint .github/workflows/ci.yml && echo "actionlint clean"
```

Expected: clean.

- [ ] **Step 4: Confirm the asset check can actually fail**

The "Verify every asset arrived" step is a guard, so prove it is not vacuous. Locally:

```bash
mkdir -p /tmp/relcheck/artifacts/desktop-bundle-x86_64-unknown-linux-gnu
cd /tmp/relcheck
# Paste the script body from Step 2 into a file and run it.
# Expected: exits 1 with "no .deb in the bundle artifact" and lists what it found.
```

Then add a dummy `.deb` and both sidecar files and confirm it exits 0. A guard that has only ever been observed passing has not been tested.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "$(cat <<'EOF'
ci: publish a GitHub Release from a v* tag

Downloads what the desktop job built and attaches the x86_64 .deb plus both
Burrito sidecars to a Release at the tag. Notes are generated from commits
since the previous tag, which the squash-merge convention makes readable
without maintenance.

needs: [check, desktop] is the substance rather than ceremony: check is where
the tag-vs-version guard runs, so a mismatched tag never publishes, and
depending on the whole desktop matrix means a broken aarch64 sidecar blocks the
Release instead of producing a partial one.

permissions: contents: write is scoped to this job; the workflow default stays
read, so no other job gains repository write access.

An explicit asset check runs before `gh`, so a missing file produces a message
naming it and listing what did arrive, rather than a gh usage error.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Correct every document this falsifies

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-08-02-linux-desktop-bundle-design.md` (§10, §11, §12)
- Modify: `docs/superpowers/2026-07-30-follow-ups.md`

This is spec §8. Each item is a claim a reader would otherwise act on, so the change is not done until they are all correct.

- [ ] **Step 1: README — how to install a release**

Add a section after "Running the desktop app". The existing section describes only the macOS bundle paths, so say plainly that Linux users get a package:

```markdown
## Installing a release

Linux `.deb` packages are attached to every [release](https://github.com/adsouza/armchair-metropolist/releases).
Download the `.deb` and:

```bash
sudo apt install ./armchair-metropolist_<version>_amd64.deb
```

x86_64 only. The single-file Burrito sidecar is also attached for both x86_64 and
aarch64 — it runs the server without the desktop window, which is what you want on
a machine with no display.
```

- [ ] **Step 2: README — how to cut a release**

Add immediately after it:

```markdown
## Cutting a release

The version lives in four files and they must agree, so move them together:

```bash
mix version.set 0.2.0
git commit -am "Release 0.2.0" && git push
git tag v0.2.0 && git push origin v0.2.0
```

The tag is checked against the declared version in CI, so a tag that disagrees
fails before anything is published. Bumping the version is not optional
bookkeeping: a Burrito binary unpacks its payload once, keyed on the app version,
so two packages sharing a version means the second one installs code that never
runs.
```

- [ ] **Step 3: Bundle design §10 — annotate the superseded claims**

All of this is in §10's **last bullet and its indented sub-paragraph**, not in three separate bullets. Do not restructure the section; append a dated note to that sub-paragraph:

```markdown
  **Done, 2026-08-03** — see `2026-08-03-tag-driven-releases-design.md`. Three
  predictions in this paragraph need correcting rather than deleting. The tag did
  become a fifth site in §6's check, but a *conditional* one: that function also
  runs in the PR gate and the pre-push hook, where an unconditional site would read
  nil and the nil-guard is fatal. The arm64 `cargo install tauri-cli` was
  considered and **declined** — Releases carry the x86_64 .deb and sidecars for
  both arches, so the ~5-minute install and a full compile on a slower runner buy
  nothing yet. And the 14-day expiry no longer applies to released artifacts,
  though it still applies to the per-merge sidecars, which are still uploaded and
  still carry the payload-cache problem described above.
```

- [ ] **Step 4: Bundle design §11 — correct the Flatpak runtime claim**

§11 risk 1 says the runtime's glibc "was **not** verified during this design and is the first thing to establish". Append:

```markdown
   **Partly established, 2026-08-03.** GNOME 47 moved to freedesktop-sdk 24.08
   (`gnome-build-meta!3447`), and freedesktop-sdk 24.08 ships glibc 2.40. Against a
   `libc6 (>= 2.39)` floor that means **`//46` proposed above was very likely never
   viable** and `//47`/`//48` clears it. Read from upstream merge requests, not
   measured inside a runtime, so treat it as a lead: whatever is built must assert
   the floor by *running* the binary in the sandbox, since `flatpak-builder` exits 0
   having only copied files.
```

And to risk 2, append:

```markdown
   **Resolved for released artifacts, 2026-08-03** by tag-driven releases — see
   `2026-08-03-tag-driven-releases-design.md` §7. Still open for the per-merge
   sidecar artifacts, deliberately.
```

- [ ] **Step 5: Bundle design §12 — the sweep is now five wide**

§12 says the alignment check needs "four separate mutations, not one". Change the count and say why:

```markdown
§6's alignment check is mutated independently of the bundle, since it runs in `mix check` and needs
no Linux runner. Set each of the **five** sites to a different version **one at a time** and confirm
`mix check` goes red for each — five separate mutations, not one. The fifth is the release tag, live
only when `RELEASE_TAG` is set, so run that one as `RELEASE_TAG=v9.9.9 mix check`; also confirm
`RELEASE_TAG=garbage mix check` fails via the *nil-guard* rather than the disagreement message, which
is what distinguishes a guard that fired from one that was skipped.
```

- [ ] **Step 6: Follow-ups doc — move the release work to done**

In `docs/superpowers/2026-07-30-follow-ups.md`, under the section recording resolved work, add:

```markdown
* **Tag-driven GitHub Releases — done 2026-08-03.** A `v*` tag now cuts a Release
  carrying the x86_64 `.deb` and both sidecars, with the tag checked against the
  four declared versions before anything publishes, and `mix version.set` to move
  them together. This closes the payload-cache bug for anything anyone installs:
  distinct releases now carry distinct versions. It stays open for the per-merge
  sidecar artifacts, which are still uploaded on every push to main and are still
  the same Burrito binary. Spec: `specs/2026-08-03-tag-driven-releases-design.md`.
```

- [ ] **Step 7: Verify no stale cross-reference survives**

```bash
cd /Users/adsouza/Code/armchair-metropolist
grep -rn 'All four must carry' . --include='*.md' --include='*.exs' || echo "clean"
grep -rn 'four separate mutations' docs/ || echo "clean"
grep -rn 'ps:migrate' docs/ README.md | head
```

The first two must print `clean`. The third is expected to show `docs/deploying.md`'s entry, which is correct as written — it documents why *not* to use `ps:migrate`.

- [ ] **Step 8: Run the full gate**

```bash
mix check
```

Expected: green, `[versions] 0.1.0`.

- [ ] **Step 9: Commit**

```bash
git add README.md docs/
git commit -m "$(cat <<'EOF'
docs: catch the guides up with tag-driven releases

README gains how to install a release and how to cut one, including why the
version bump is load-bearing rather than bookkeeping.

The bundle spec's §10 predicted this work; two of its three predictions were
wrong and are corrected rather than deleted — the tag site is conditional, and
arm64 .deb bundling was declined rather than made affordable. §12's mutation
sweep is now five sites wide, and the fifth needs its own nil-guard case.

§11's Flatpak deferral had flagged the runtime glibc as unverified; recorded
what upstream says, including that the //46 it proposed was very likely never
viable against a libc6 (>= 2.39) floor.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage.** §3 trigger → Task 3 Step 1. §4 conditional fifth site → Task 1. §5 job wiring → Tasks 3 and 4. §6 `mix version.set` → Task 2. §7 what is and is not fixed → Task 5 Steps 3, 4, 6 record it. §8 five doc updates → Task 5, one step each. §9 verification → Task 1 Steps 6-11, Task 2 Steps 4-7, Task 3 Step 6, Task 4 Step 4; rows 7 and 8 are real tag pushes and belong to the post-merge close-out below, not to a task.

**Type consistency.** `version_sites/0` is produced in Task 1 and consumed in Task 2's `verify!/0` under that exact name, returning `[{binary(), binary() | nil}]`. Artifact names `desktop-<target>` and `desktop-bundle-x86_64-unknown-linux-gnu` are produced in Task 3 and consumed verbatim in Task 4. `bump_mix_exs/2`, `bump_tauri_conf/2`, `bump_cargo_toml/2` are named identically in the tests and the implementation.

**Known gap, deliberately outside the tasks.** Nothing here proves the `release` job runs, because that needs a real tag push. Close it out after merge:

1. `git tag v0.0.1 && git push origin v0.0.1` — `check` must go **red** on the version guard and no Release may appear. Then `git push --delete origin v0.0.1 && git tag -d v0.0.1`.
2. `git tag v0.1.0 && git push origin v0.1.0` — a Release must appear with three assets. This is not a throwaway: `0.1.0` is the current version, so the first genuine release doubles as the positive test.

Step 1 must run first. If it is skipped, a green step 2 proves only that publishing works, not that the guard blocks anything — and the guard is the entire point of the design.
