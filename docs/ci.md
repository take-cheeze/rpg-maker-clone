# Continuous integration

[`.github/workflows/build.yml`](../.github/workflows/build.yml) is the one CI
workflow. It runs on pull requests to `master`, pushes to `master`, merge-queue
runs, manual dispatch and (for the Cloudflare preview only) `/preview` comments.
Deployment is covered in [deploy.md](deploy.md).

## Native SDL probes

On Linux, `exe_open`, `render_probe`, `audio_probe` and `error_dump` use reserved
Xvfb displays and set `SDL_VIDEODRIVER=x11` through CTest. This ensures SDL uses
the virtual display even when the parent environment describes a Wayland
session. The audio probe retains `SDL_AUDIODRIVER=dummy`. Normal desktop runs
continue to select their backend through SDL's usual configuration.

## bc2cpp gate

The status check `bc2cpp` is the aggregate of `bc2cpp-build`, every
`bc2cpp-checks (<shard>)` and every `bc2cpp-width (<variant>)` job. Require
`bc2cpp` rather than the individual shards, so adding a shard needs no settings
change.

### Superseded runs

A push to a pull request cancels the run still going for that PR's previous
commit (workflow-level `concurrency`, keyed on the PR number). Master pushes,
merge-queue runs, manual dispatches and `/preview` comments use a per-run group
and are never cancelled.

### Mutation checks run off pull requests

On `pull_request` runs the `bc2cpp-checks` job sets `CI_SKIP_MUTANTS=1`, and
`scripts/ci_timed_checks.rb` then drops every `*_mutation_check.rb` command and
strips `*_MUTANTS=1` switches, so each shard keeps its fixture checks but not the
mutant rebuilds. Master pushes, merge-queue runs and manual dispatch run them
all, so a mutation regression blocks the merge queue rather than the PR. Timing
estimates in the shard table include the mutants and apply to those runs. To run
them on a PR, use `workflow_dispatch` on its branch.

### Splitting long shards

`hot-only` ran its two ~15 minute reviewed-set checks back to back, so
`hot-proven-miss` now runs `bc2cpp_proven_miss_check`. `coverage` takes the three
slowest checks out of `fast` (`bc2cpp_coverage_check`, the optcarrot coverage
check and `rescue_shadow`). Timings come from the "Check timings" job summary.

### Width shards

The `int32` variant is split into `int32-a` and `int32-b` (both build the same
32-bit libmruby via the matrix `build:` field) so its 40 minute run no longer
sets the workflow's wall clock. Add new 32-bit legs to whichever is shorter.

### Check shards

`bc2cpp-checks` is a matrix; each shard is its own job with a 45 minute
timeout, and the aggregate gates on the matrix as a whole
(`needs: bc2cpp-checks`), so renaming or adding a shard touches neither the
aggregate nor branch protection. Every check is listed in exactly one shard.
Keep each shard under about 25 minutes so one more check does not reach the
timeout; raise the timeout only as a last resort.

The compiled-versus-interpreted fixtures that need a full-core mruby are split
three ways, because each step takes minutes and one shard had reached the
timeout (a run of the old single `core-mrbtest` shard took about 43 minutes):

| Shard | Checks | Approx. |
| --- | --- | --- |
| `core-mrbtest` | block/yield-free/exact-receiver (+ `core_body_exact` and `core_singleton_audit`, ADR 0359, about 1 min)/return-class, `step_inline`, `eqq_direct`, `define_method_sites`, `resumable`, `io_puts_model`, `fixnum_overflow`, `numeric_slow`, `index_closed` (ADR 0365, about 2 min), `tuple_return` (ADR 0311, +30 s), mruby's own suites | 20 min |
| `core-flow` | `exact_receiver_flow` and its mutation check, `computed_send` with `CSEND_MUTANTS=1` | see the timing table |
| `core-tables` | `frozen_tables` and its mutation check (ADR 0306) | see the timing table |
| `call-results` | `call_results` and its mutation check (ADR 0309; its 32-bit leg runs in `bc2cpp-width (int32-a)` or `(int32-b)`) | see the timing table |
| `native-wrappers` | `exact_native_wrappers` (ADR 0307) and its eight mutants | 5 min |
| `core-mutants` | `unlisted_class_call` with `UCC_MUTANTS=1` (seven mutant rebuilds) | 23 min |
| `block-arm-reach` | `block_arm_reach` with `BR_MUTANTS=1` (ADR 0310: six mruby builds, eight generator mutants) | 10 min (local, 4 cores) |
| `escape-analysis` | `escape_analysis` (unit, generated code, six mruby builds) and its mutation check (ADR 0316: eighteen mutants and a control) | est. 12 min (local: 6 min + 2 min) |
| `core-exact-direct` | `core_exact_direct` with `CX_MUTANTS=1` (ADR 0314: four mruby builds each run compiled and interpreted, nine generator mutants and a control) | 15 min (4 cores) |
| `captured-locals` | `captured_local_class` (generated code, full-core and core-only runs) and its mutation check (ADR 0308) | est. 15 min |
| `constructor-pools` | `constructor_pools` (generated code, full-core and core-only runs) and its mutation check, 13 mutants plus a control (ADR 0313); the 32-bit run is in `bc2cpp-width (int32-a)` or `(int32-b)` | est. 15 min |
| `numeric-constants` | `numeric_constants` (generated code with fifteen withdrawal worlds, full-core and core-only runs) and its mutation check, 15 mutants plus a control (ADR 0318; the mutation check ran 12 min locally with three jobs); the 32-bit run is in `bc2cpp-width (int32-a)` or `(int32-b)` | est. 20 min |
| `native-class-arms` | `native_class_arms` (generated code with sixteen withdrawal worlds, full-core and core-only runs over the base fixture, the compiled core and the method_missing, module and reopened-Hash worlds) and its mutation check, 13 mutants plus a control, mutants stop at the first matching FAIL line (ADR 0323); the 32-bit run is in `bc2cpp-width (int32-a)` or `(int32-b)` | est. 20 min |
| `numeric-intervals` | `numeric_intervals` (generated code with five withdrawal worlds and both kill switches, full-core and core-only runs) and its mutation check, 9 mutants plus a control (ADR 0326); the 32-bit run is in `bc2cpp-width (int32-a)` or `(int32-b)` | est. 10 min |
| `setter-pools` | `setter_pools` (the native store audit, generated code with the withdrawal worlds and three kill switches, a full-core run interpreted against compiled including the loud outside-setter and composed-name failures) and `aliased_names` (ADR 0370; its mutation check, eleven mutants: `setter_pools_mutation_check`) | est. 6 min |
| `call-facts` | `call_facts` (generated code with ten withdrawal worlds, full-core and core-only runs) and its mutation check, 10 mutants plus a control (ADR 0317), `block_send_report` (ADR 0325, generated code only, 15 s), `dead_arm_report` (ADR 0330, generated code only, 15 s), `receiver_proof_report` (ADR 0331, generated code only, 30 s), `native_ivar_scopes` (ADR 0332, source audit, withdrawal worlds, full-core/core-only parity for Window/Sprite/Plane/Tilemap and subclasses, eleven mutants plus a control, including bitmap setter families in ADR 0337), `native_setter_report` (ADR 0337, byte-identical code, input masks, mentions and incomplete caller coverage), `native_class_results` (ADR 0333, pinned-source audit, mixed Ruby/native returns, withdrawal worlds, full-core/core-only parity, eight mutants plus a control), and `native_string_results` (ADR 0334, linked native and Struct alias audits, generated withdrawal cases, full-core/core-only parity and eleven mutants plus a control), and `native_collection_results` (ADR 0335, copy/collection source and helper audits, override withdrawal, full-core/core-only parity and seven mutants plus a control), and `native_array_transforms` (ADR 0336, name-wide allocation contracts, File.join subclass boundary, source/helper audits, full-core parity and seven mutants plus a control), and `core_ruby_results` (ADR 0338, actual core bytecode, aliases, block exit/override/captured-write refusals, full-core parity and ten mutants plus a control); the 32-bit runs are in `bc2cpp-width (int32-a)` or `(int32-b)` | est. 16 min |
| `ext-prefix` | `ext_prefix` (decoder cases, folded listing, generated code with the kill switch, full-core and core-only runs) and its mutation check, 8 mutants plus a control (ADR 0320); the 32-bit run is in `bc2cpp-width (int32-a)` or `(int32-b)` | est. 12 min |
| `integer-constants` | `integer_constants` (unit cases for the native-definition scan and the jump onto a SETCONST, generated code, full-core and core-only runs) and its mutation check, 8 mutants plus a control (ADR 0324); the 32-bit run is in `bc2cpp-width (int32-a)` or `(int32-b)` | est. 8 min |

Shards no longer share `BC2CPP_FULL_BUILD_DIR`, so each one that needs the
full-core build makes its own (about two minutes). The times are estimates from
the per-check log timestamps of that run, not measurements of the split.

Measured job times of the first master run after the split (run 4919, wall
clock of the whole job, setup included):

| Shard | Job | `Run ... checks` step |
| --- | --- | --- |
| `core-flow` | 31 min | 28 min |
| `fast` | 18.5 min | 16 min |
| `core-mutants` | 16 min | 14 min |
| `core-mrbtest` | 14.5 min | 12.5 min |
| `optcarrot-benchmark` | 6.5 min | 3.8 min |
| `hot-only` | 6 min | 4 min |
| the other shards | 3-5 min | 1-2 min |

`bc2cpp-width (int32-a)` or `(int32-b)` took 9 min. `core-flow` is the long pole of the whole
workflow; the mutation checks inside it are the first thing to shorten.

### Reading the timing table

Every `bc2cpp-checks` and `bc2cpp-width` job runs its `checks:` block through
`scripts/ci_timed_checks.rb`, which leaves the commands exactly as written (same
shell, same order, `set -e` still stops at the first failure) and brackets each
with a stopwatch. When the step ends, pass or fail, it prints

```
== check timings (seconds  command), slowest first
    812.4  CSEND_MUTANTS=1 BC2CPP_MRUBY_CORE="$core" ... ruby scripts/bc2cpp_computed_send_check.rb
    ...
      0.1  FAILED  MRBC="$mrbc" ruby scripts/bc2cpp_foo_check.rb
   1543.9  total
```

at the end of the step log and in the job summary ("Check timings"). The
command that failed is marked `FAILED`, with the time it ran before failing;
commands after it never ran and are not listed. Lines that only set variables
(`width=...`, `export ...`) are not timed, comments are dropped. Use the table
to decide where a new check goes: put it in the shard with the most slack, and
keep each shard's total under the budget above. `ruby scripts/ci_helpers_check.rb`
(in `ruby-checks`) covers the wrapper.

### Compiler cache (sccache)

`scripts/bc2cpp_cxx.rb` is where the checks start the C++ compiler
(`${CXX:-g++}`) and where they set `CC`/`CXX` for the `rake` that builds mruby
(the full-core build, `core_mrbtest`, the width builds, the block/exact-receiver
builds). When an `sccache` is usable it goes in front of the compiler, found in
this order: `BC2CPP_SCCACHE` (a path; `0` turns the launcher off),
`CMAKE_CXX_COMPILER_LAUNCHER` (the dev shell sets it, so the checks use the same
client as the cmake steps), then `sccache` on `PATH`. Without one nothing
changes: the arguments reach `g++` untouched.

Two details make this effective rather than cosmetic:

- sccache caches a compile (`-c`), not `g++ main.cpp lib.a -o bin`. For a
  one-source build the helper therefore runs a cached `-c` and then the link.
- The preprocessed text sccache hashes contains the source path, and fixtures
  live in a fresh `mktmpdir`, so the `-c` runs inside the source's directory
  with the source and its `-I` spelled relative. Two runs of the same fixture
  then hit even though their temp directories differ.

What it does and does not buy: the fixtures themselves are small (a
`return_class` fixture compiles in under a second), so the cache matters for the
mruby builds, about 2 minutes each in CI and a handful per shard. The caches are
only written by pushes to `master` (`SCCACHE_GHA_RW_MODE`), so a pull request
sees the effect once `master` has run these steps once (the workflow compiles through
the `sccache-action` binary, not the dev shell's nixpkgs 0.15.0, whose GHA backend ignores
`SCCACHE_GHA_RW_MODE`; read-only mode needs 0.16.0 or later), and only for build
directories whose path is stable between runs (`BC2CPP_FULL_BUILD_DIR`,
`BC2CPP_BLOCK_DIRECT_DIR`, the `$RUNNER_TEMP` ones the workflow names; a check
that builds in a random temp directory still misses). Run with
`SCCACHE_DIR=... sccache --show-stats` locally to see the requests.

The full-core build is not stored with `actions/cache`: `full_or_build` treats an
existing `libmruby.a` as current and never checks the inputs (patches, the mruby
submodule, the gembox config, the compiler), so a key that missed one would hand a
stale library to every check. sccache keys on the real compile inputs instead.

### Mutant pool

The mutation checks run one subprocess per mutant, each independent. Through
`scripts/bc2cpp_mutant_pool.rb` they run up to `BC2CPP_JOBS` at a time (default
the core count, at most 4; `1` is the old serial order) and report in input
order, so the log and every `ok`/`FAIL` line read as before. Memory is small
for the generated-code mutants (the generator stays under 100 MB); a mutant that
also compiles and runs a fixture is the larger one. Two behaviours worth
knowing:

- A mutant is stopped at the first `FAIL` line that already proves it caught
  (for the checks with an expected label, the first line matching it). Every
  check prints `FAIL` only together with a nonzero exit, so the verdict is the
  same; the run just does not finish the checks after the one that fails. A
  mutant that survives runs to the end, as before.
- With `BC2CPP_FULL_BUILD_DIR` set, the pool builds the shared full-core mruby
  once before it starts, so the concurrent mutants do not race to build it.

Measured locally on a shared 4-core machine (load average 5-8, so absolute
times are inflated): `UCC_MUTANTS=1 bc2cpp_unlisted_class_call_check` took 913 s
with the old serial loop and 364 s through the pool. Expect `core-mutants` and
the CSEND/ERF mutants of `core-flow` to shorten by a similar factor on a 4-vCPU
runner; that is an estimate until a CI run reports the timing table.

Used by `bc2cpp_unlisted_class_call_check` (`UCC_MUTANTS`),
`bc2cpp_computed_send_check` (`CSEND_MUTANTS`),
`bc2cpp_exact_receiver_flow_mutation_check`,
`bc2cpp_loop_installers_mutation_check`, `bc2cpp_getidx_integer_arm_check`
(`GIA_MUTANTS`), `bc2cpp_block_arm_reach_check` (`BR_MUTANTS`),
`bc2cpp_core_exact_direct_check` (`CX_MUTANTS`), and the
`bc2cpp_frozen_tables_mutation_check`,
`bc2cpp_call_results_mutation_check`, `bc2cpp_class_pools_mutation_check`,
`bc2cpp_tuple_return_mutation_check` (always, no flag needed).
`ci_helpers_check.rb` covers the pool itself.

Two of these keep their `MUTANTS` as a Hash and pass `MUTANTS.to_a`, because the
pool indexes its items and needs a sequence; declaration order is preserved, so
the log reads as before. `core_exact_direct` runs its unmutated control first and
alone, ahead of the pool: it is what says the copy-and-run path itself still
works, so running it beside a mutant would attribute a broken path to that
mutant. Its mutant directories carry an index, because two mutants may edit the
same generator file and would otherwise share — and delete — one copy.

### Width builds (ADR 0300)

The Emscripten, Wio and PSP targets use a 32-bit `mrb_int`; Wio and PSP also
have no mruby-bigint. `bc2cpp-width` re-runs the compiled-versus-interpreted
checks on a libmruby built by `scripts/bc2cpp_width_build.rb`:

| Variant | Build | Checks |
| --- | --- | --- |
| `int32` | full-core, `-DMRB_32BIT -DMRB_INT32` (31-bit Fixnums) | `numeric_slow`, `fixnum_overflow`, `step_inline`, `lcf_row_flow`, `call_results` |
| `nobigint` | full-core without mruby-bigint / mruby-rational | `numeric_slow` |
| `int32` | full-core, `-DMRB_32BIT -DMRB_INT32` (31-bit Fixnums) | `numeric_slow`, `index_closed`, `fixnum_overflow`, `step_inline`, `lcf_row_flow`, `tuple_return`, `zero_direct` |
| `nobigint` | full-core without mruby-bigint / mruby-rational | `numeric_slow`, `index_closed`, `getidx_integer_arm`, `tuple_return`, `zero_direct` |

The 32-bit build is the 64-bit host with the targets' arithmetic defines, so it
does not exercise 32-bit pointers. To run a variant locally, after the mruby
patch chain has been applied (any cmake build does it; the numeric-slow check
links `mrb_int_mod_impl` and friends from `patches/mruby-expose-misc-bodies.patch`,
ADR 0367, so a libmruby built from an unpatched tree fails to link):

```bash
ruby scripts/bc2cpp_width_build.rb int32 /tmp/w32
BC2CPP_MRUBY_FULL32=/tmp/w32/host BC2CPP_MRBC32=/tmp/w32/host/bin/mrbc \
  MRBC=<64-bit host mrbc> ruby scripts/bc2cpp_numeric_slow_check.rb
```

`numeric_slow` also needs the tree to carry `patches/mruby-expose-collection-op-bodies.patch` (ADR 0366): the
`- & | <<` helpers call the exported `Array#-`, `&`, `|`, `String#<<` and `IO#<<` bodies, and the libmruby it runs
against must be built from that patched tree.

A check whose environment variable is missing prints `SKIP` and exits 0; the
job fails instead when the libmruby it should have built is absent.

The `fast` shard also runs the Profiler block-result checks and mutation
checks (ADR 0344), including full-core interpreter parity with profiling enabled
and disabled, captures, nested helper frames and nonlocal returns.

## Cross-PR interaction (merge queue)

A pull request is tested against the `master` it branched from. Two PRs that
are each green can still break `master` together. The workflow listens for
`merge_group` events so it can be a merge queue's gate, but **the repository
owner has to turn the protection on** (Settings, not code):

1. **Preferred: a merge queue.** Settings, Rules, Rulesets (or Branches, branch
   protection rule for `master`): enable **Require merge queue**. Keep the
   required status checks (at least `bc2cpp`, plus the other required jobs) and
   set a build concurrency of 1 to 3. The queue then runs this workflow on each
   PR merged onto the current `master` and the PRs ahead of it, and merges only
   on success. Auto-merge keeps working: it enqueues the PR.
2. **Cheaper alternative.** Enable **Require branches to be up to date before
   merging** on the same protection rule. A PR must then contain the latest
   `master` before it merges, so CI has seen the combination, at the cost of
   re-running CI after every other merge.

Notes for the queue run: `deploy-pages` still needs a `push` to `master`, and
`preview-cloudflare` only an `issue_comment`, so neither fires on `merge_group`.
The `changes` job's path filter (dorny/paths-filter) has not been exercised on a
`merge_group` run; watch the first queued PR for it. A required check must be reported on
`merge_group` as well as on `pull_request`; every job here has no event filter
beyond excluding `issue_comment`, so it is.

### Call-context receiver results

The bc2cpp core-mrbtest shard runs the call-context result parity check and its
mutation check. They exercise exact self, positional inputs, inherited overrides,
cache separation and withdrawal for uncertain returns or unsupported method
shapes, captured writes and nonlocal block returns (sixteen mutants plus a
control). See ADRs 0351 and 0353. Native-summary withdrawal checks and profiler mutation
checks disable call-context results so an independent local proof cannot mask
the proof path they are testing. The dedicated call-context checks exercise the
enabled analysis.

### Enumerator wrapper compilation

The bc2cpp core checks run `bc2cpp_enumerator_wrappers_check.rb` and its mutation
check. They verify the seven admitted wrappers' unconditional Fiber guards,
saved bytecode registration, admission gates and runtime parity for yielding
callbacks, state changes, overrides and GC. See ADR 0350.

### Compiled core definers and the Hash comparison arm

The `core-flow` shard also runs `bc2cpp_core_compiled_cmp_check.rb` and its mutation check
(ADR 0371). A closed world that compiles mruby's own Ruby puts the compiled `Hash#<`, `<=`, `>`
and `>=` in the Hash arm of the four comparison helpers; the check covers the generated code, the
negative worlds (reopened, prepended, aliased, outside or computed definers, a `==` that may
yield, `method_missing`, a singleton, a build without mruby-hash-ext, an open world, no core
compile, the `BC2CPP_CORE_COMPILED_CMP=0` kill switch), and a run of every helper against the
interpreted operator on a full-core build. The compiler also prints `== core-source methods left
interpreted ==` with a reason and the language features per method, which the coverage report's
core line counts.

### User receiver unions

The core-mrbtest shard runs user receiver union parity and mutation checks.
They verify shared-body direct calls, every family member, differing overrides, unknown and nil bits,
constructor lookup, hierarchy bounds and outside replacements. See ADR 0352.

ADR 0355 expands call-context checks to positional defaults, rest and trailing
arguments, with interpreter parity and fourteen proof-condition mutants plus a
control. The core shard also runs `bc2cpp_context_arguments_check.rb` and its
seven-mutant binding checker.

### Numeric native conversions

The core-mrbtest shard runs enabled and disabled Integer conversion parity and
nine proof-condition mutants plus control. Cases include fixnums, bigints beyond
64 bits, decimal ABI, mixed numeric inputs, overrides, singleton makers, open
worlds, wrong arity and blocks. See ADR 0357.

The conversion parity check also runs in both width shards with width-safe
literals and matching bigint defines. Visibility changes withdraw the numeric
proof alongside altered method lookup.

### Fresh literal element receivers

The core-mrbtest shard runs enabled and disabled literal element parity checks,
plus six proof-condition mutants and their control. They cover exact primitive
results and withdrawal for captured writes, effects, branch entries, unknown
indices and out-of-bounds reads. See ADR 0354.

ADR 0356 adds `bc2cpp_readonly_call_effects_check.rb` and its mutation checker to
the core shard: readonly getters, receiver unions, unknown and outside writers,
strict opcode/arity checks, runtime parity, and thirteen mutants plus a control.

The native class-arm and join-dominance checks disable exhaustive user receiver
unions so their guarded fallback assertions continue to exercise those proof
paths. The receiver-union suite separately checks exhaustive dispatch.

### Native arm Integer guards

The core shard runs `bc2cpp_native_int_guard_check.rb` enabled and disabled, plus
its mutation check (control, switch-off control and six mutants covering the
gate, the kind filter, the proof's register test and the position argument).
The check pins both emitters' shape for every answer the Fixnum proof can give
and drives the real proof over its own refusals; the generated-code section
covers a closed and an open world. See ADR 0358 and
[bc2cpp-native-int-guards](bc2cpp-native-int-guards.md).

### The zero? helper through compiled core

The `core-flow` shard also runs `bc2cpp_zero_direct_check.rb` and its mutation check (ADR 0373); the `int32`
and `nobigint` width legs run the same check against their own libmruby. A closed world that compiles
mruby's own Ruby has `bc2cpp_slow_zero` call the compiled `Numeric#zero?` for every Numeric that is not a
Float, raise the `File.zero?` argument error for those class objects, and keep the NoMethodError proof for
the rest. The check covers the generated code, twelve negative worlds (reopened, aliased, included,
prepended, singleton or class-level definers, a computed installer, `method_missing`, a `==` that may
yield, a build without mruby-numeric-ext or mruby-io, an open world, no core compile, both kill switches)
and a run of the helper against the real `zero?` (values, error class and message, user `==` calls, the
by-name call count) at every width, in the closed world and in four worlds that must keep the by-name helper.
