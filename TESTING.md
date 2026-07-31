# Testing

150 tests (145 tests, 5 properties). Coverage 92.98%, gated at 90%. `Domain`,
`Domain.Services` and `UseCases` sit at 100% and should stay there.

## Running the tests

Needs a local Postgres: the Ecto adapter's tests run against a real database on
purpose, and `mix test` creates and migrates it for you.

```bash
mix check
```

That is the gate, and the thing to run before committing. It is defined once in
`mix.exs` so it cannot drift between a laptop and CI, and it is three steps:

| step                                   | why it is there                                                                                                                                                                         |
|----------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `format --check-formatted`             | formatting is not a review topic                                                                                                                                                        |
| `compile --force --warnings-as-errors` | **this is what enforces `boundary`.** Architecture violations are only *warnings*, so nothing else fails on them. `--force` matters too: boundary only reports on modules it recompiles |
| `sobelow`                              | Phoenix security scan, configured in `.sobelow-conf`. Fails on any finding, which is only tolerable because the existing ones are annotated at the source — see below                    |
| `test --cover`                         | the suite, plus the coverage threshold                                                                                                                                                  |

### The security scan

`mix sobelow` runs as part of the gate and is set to fail on **any** finding, at
`.sobelow-conf`'s `exit: "low"`. That is workable only because the handful of real
findings are individually annotated where they occur:

* three `Misc.BinToTerm` — `binary_to_term` in both snapshot adapters. Sobelow flags
  these even with `[:safe]`, correctly: `:safe` blocks atom, pid and function
  creation but not a deliberately huge or deeply nested term. Accepted because the
  input is a snapshot this application wrote, and reaching it needs filesystem or
  database write access.
* three `Traversal.FileModule` — file paths in `FileSnapshotStore`, built from
  `:snapshot_dir` config rather than from any request.
* one `Config.CSP` in `.sobelow-conf`'s `ignore`, because a CSP *is* set — by a
  per-request plug carrying a nonce, which Sobelow's check cannot see since it looks
  for a static map passed to `:put_secure_browser_headers`.

**Adding a `# sobelow_skip` is a claim; state the reasoning next to the code**, not
in a config list where it rots away from what it describes.

One trap, since it is exactly the failure this document warns about: `.sobelow-conf`
must say `exit: "low"`, a **string**. Sobelow matches that value against
`:high`/`:medium`/`:low` with a `_ -> 0` catch-all, so `exit: true` reports findings
and still exits 0 — a gate that cannot fail. Verify by deleting a `sobelow_skip`
annotation and checking `mix sobelow; echo $?` is non-zero.

Day to day:

```bash
mix test                                              # the suite
mix test test/armchair_metropolist/domain             # one directory
mix test test/.../city_engine_test.exs:84             # one test, by line
mix test --cover                                      # with the coverage report
mix test --failed                                     # only what failed last run
mix test --seed 0                                     # disable random ordering
```

`mix test --force` recompiles the suite, which matters when you are checking that a
compiler warning is gone — test files can otherwise report a stale clean run.

There is one slow test, tagged so you can find it but **not** excluded from the
gate, because at ~0.7s excluding it would buy nothing:

```bash
mix test --only cold_vm     # snapshot decoding in a VM that has never loaded the entity modules
```

It exists because of a real data-loss bug: `:erlang.binary_to_term/2` with `:safe`
refuses to create atoms, so a snapshot written by one VM could not be read by a
fresh one until the entity modules were loaded first.

## How the suite is organised

Testing strategy follows the architecture, because the architecture is what makes
most of it easy.

**`Domain` — pure, no test doubles anywhere.** Entities and services are
deterministic functions over data. There is nothing to stub, so these tests are
plain input/output assertions and all `async: true`.

**`Domain` purity is itself tested.** `domain_purity_test.exs` reads each Domain
module's compiled BEAM imports table and fails on `GenServer`, `Agent`, `Task`,
`Process`, and on `:erlang` functions named `spawn`, `send`, `self`, `exit` or
`monitor`. This closes a gap `boundary` cannot: those modules live in the `:elixir`
application, which boundary treats as unconditionally allowed, so a Domain module
could spawn processes and send messages with `type: :strict` and `deps: []` still
compiling clean — verified empirically before the denylist existed. Reading the
imports table rather than the source means aliases, imports and macro-generated
calls cannot evade it.

**`UseCases` — driven through injected ports.** `Domain` declares
`SnapshotRepository` and `Notifier`; tests pass `test/support/stub_*.ex`
implementations. No mocking library, because the ports exist.

**Adapters — against the real thing.** `SnapshotStore` runs on Postgres and
`FileSnapshotStore` on the filesystem. An adapter tested only through a stub is a
test of the stub.

Both are held to **one shared contract**: `test/support/snapshot_repository_contract.ex`
is `use`d by both adapter test modules, so a new adapter cannot quietly implement
less than an existing one. It was deliberately merged back into a single module
after being split, precisely so a newcomer cannot `use` one half and skip the other.

**OTP behaviour — real processes, no sleeping on hope.** `CityEngine` and
`TickServer` tests start supervised instances with `start_supervised!/1` and assert
on messages and PubSub broadcasts rather than on timing.
`test/support/slow_snapshot_repository.ex` exists to make the shutdown path
observable — it delays a write so the test can prove `terminate/2` actually
completes it.

**LiveView — through the rendered page.** `simulator_live_test.exs` drives the real
LiveView and asserts on what a browser would receive, including stream inserts and
removals.

**Properties, where a property is genuinely stronger.** `domain_properties_test.exs`
uses `stream_data` with generators in `test/support/city_generators.ex` — for
invariants like "a delta contains exactly the nodes whose display signature
changed". Note the anti-pattern recorded in the follow-ups doc: permuting map
insertion order and asserting equal output tests an Erlang invariant, not this
code.

### Conventions

* `async: true` by default. `async: false` only where a test touches genuinely
  global state — application env, OS env, the sandbox mode, or a named singleton
  process. Each such module says why in its `@moduledoc`.
* `test/support/` is excluded from coverage. It is scaffolding; counting it would
  measure how well the helpers test themselves.
* Prefer `===` over `==` for numeric assertions. `assert avg_health == 0.0` passes
  for integer `0`, which is how one vacuous test survived review.

## Manual verification

Some things cannot be reached from ExUnit and are checked by hand. Both targets have
a recipe:

**The web app** — `mix phx.server`, then place infrastructure and watch the grid.
Resource satisfaction is checkable by arithmetic: six residential blocks against
baseline municipal capacity give power 44.4% (40÷90), water 55.6%, waste 66.7%.
Checkpoints land every 50 ticks; closing the server writes a final snapshot, and
restarting should resume at that tick with exactly the surviving nodes.

**The desktop app** — see [`README.md`](README.md) for the build, and
[`docs/superpowers/2026-07-30-follow-ups.md`](docs/superpowers/2026-07-30-follow-ups.md)
before debugging one. The short version: verify the sidecar's exit status and bound
address, not the window's appearance, and remember that a rebuilt Burrito binary
runs stale code unless its payload cache is evicted.

**A deploy** — see [`docs/deploying.md`](docs/deploying.md), which includes the
curl commands and, importantly, why a WebSocket check needs `--http1.1` and a
negative-origin control.

### Choose instruments whose silence means something

Three times in this project a probe gave the wrong answer because the *instrument*
was broken, not the system:

* `IO.puts` in a Burrito sidecar's boot path never reaches stdout, which was read
  as "this code never ran" and produced a documented-and-wrong root cause.
* `curl` negotiates HTTP/2 over TLS, where a WebSocket `Upgrade:` header is
  invalid — a 400 that looked like a broken endpoint.
* `find -newermt` is not a BSD flag, so a search for recent files silently
  returned nothing rather than erroring.

Prefer a probe with a positive, readable result — set a value and read it back —
so a null result is distinguishable from a dead channel. Before believing "X never
happened", show the same probe firing where it should.

## The two rules

Both came out of tests in this repository that could not fail. The catalogue is in
[the follow-ups doc](docs/superpowers/2026-07-30-follow-ups.md#a-note-on-test-design-learned-the-hard-way);
these are the rules that came out of it.

**1. Never write a `refute` without first asserting the positive case.** A
refutation against something that never occurs is always true. One
`refute html =~ ~s{id="6:6"}` hid three Critical defects behind a green suite,
because node removal was entirely broken while every id on the page was actually
`"nodes-6:6"` — so the string being refuted never appeared either way.

**2. A test you have not seen fail is not yet a test.** Before trusting one, break
the code it covers and confirm it goes red.

### Mutation testing by hand

There is no mutation-testing library here; it is done deliberately and only where
it counts — a new invariant, a bug fix, anything whose test you have not watched
fail.

```bash
# 1. Confirm green.
mix test test/path/to/the_test.exs

# 2. Break the code it covers — invert a comparison, drop a clause, return a
#    constant, gut a function body.
#    Keep the change trivially revertible; a backup copy is enough.
cp lib/path/to/module.ex /tmp/module.ex.bak
$EDITOR lib/path/to/module.ex

# 3. The test MUST now fail. If it still passes, the test is the problem.
mix test test/path/to/the_test.exs

# 4. Restore, and confirm green again.
cp /tmp/module.ex.bak lib/path/to/module.ex
mix test test/path/to/the_test.exs
```

Two failure modes to watch for, both of which have happened here:

* **The mutation is caught by a different test than the one you are checking.**
  Run the specific file, and read *which* test failed. In `release_test.exs` a
  gutted `migrate/0` failed one of two tests — the other was vacuous.
* **The assertion is satisfied by pre-existing state.** `assert table_exists?(…)`
  after running migrations passes when the table was already there. A test must
  establish the precondition it depends on, or claim less.
