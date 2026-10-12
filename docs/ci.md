# Continuous integration

[`.github/workflows/build.yml`](../.github/workflows/build.yml) is the CI
workflow. It runs on pull requests to `master`, pushes to `master`, merge-queue
runs, manual dispatch and (for the Cloudflare preview only) `/preview` comments.
The long bc2cpp jobs are in their own workflow,
[`.github/workflows/bc2cpp-nightly.yml`](../.github/workflows/bc2cpp-nightly.yml),
which runs once a day and on demand ("Nightly bc2cpp" below).
Deployment is covered in [deploy.md](deploy.md).

## Native SDL probes

On Linux, `exe_open`, `render_probe`, `audio_probe` and `error_dump` use reserved
Xvfb displays and set `SDL_VIDEODRIVER=x11` through CTest. This ensures SDL uses
the virtual display even when the parent environment describes a Wayland
session. The audio probe retains `SDL_AUDIODRIVER=dummy`. Normal desktop runs
continue to select their backend through SDL's usual configuration.

## bc2cpp gate

The status check `bc2cpp` in `build.yml` reports `bc2cpp-build` (skipped on purpose for
a docs-only change). Every `bc2cpp-checks (<shard>)` and `bc2cpp-width (<variant>)` job is in
`bc2cpp-nightly.yml` and is not part of this check. Require `bc2cpp` and nothing
from the nightly workflow: those jobs do not run on a pull request.

### Nightly bc2cpp

A pull request or a push runs only `bc2cpp-build`. The long jobs, the `bc2cpp-checks` shard matrix and the
`bc2cpp-width` build, are in `.github/workflows/bc2cpp-nightly.yml`, which runs on a daily schedule
(cron `23 17 * * *`, UTC, on the default branch) and on **Run workflow** (`workflow_dispatch`, pick the
branch). Nightly and manual runs are not pull requests, so they run the mutation checks and the
optcarrot benchmark too, and the nightly run (default branch) is the only one allowed to write the
sccache.

What this gives up: a pull request, a push to `master` and a merge-queue run are no longer checked by
the long shards before merge. A regression shows up in the next nightly run, as a failed run in the
Actions tab (GitHub also emails a failed scheduled run). To check a branch earlier, run the nightly
workflow on it. Nothing in that workflow is a required status check, so a red nightly run does not
block a merge.

### Superseded runs

A push to a pull request cancels the run still going for that PR's previous
commit (workflow-level `concurrency`, keyed on the PR number). Master pushes,
merge-queue runs, manual dispatches and `/preview` comments use a per-run group
and are never cancelled.

### Host Ruby uses YJIT for bc2cpp

`bc2cpp-build` and both nightly job families set `RUBY_YJIT_ENABLE=1` for the
Nix-provided CRuby. Rake, the check harnesses and their Ruby code-generation
subprocesses inherit it, including mutant generators. A step after the Nix
environment export verifies `RubyVM::YJIT.enabled?` and logs `RUBY_DESCRIPTION`,
so losing JIT support fails visibly instead of silently restoring slower runs.
This accelerates host analysis; the generated C++ and target mruby VM are unchanged.
See [ADR 0408](adr/0408-bc2cpp-ci-yjit.md) for measurements and the memory tradeoff.

For a local comparison, run the same generator or check with
`RUBY_YJIT_ENABLE=0` and `RUBY_YJIT_ENABLE=1`. The environment switch is documented
in [Ruby's YJIT manual](https://docs.ruby-lang.org/en/3.4/yjit/yjit_md.html).

### Repeated bytecode dataflow queries

bc2cpp's `BytecodeIR::Program` reuses reaching-definition and write-dominance
answers for the same instruction/register query. Each body keeps at most 1,024
answers per query type, including refusals. Query options and opaque registers
are part of the key; mutable opaque sets and refusal diagnostics bypass reuse.
Returned definition arrays and register strings remain private to each caller.
The existing dataflow check compares answers with an independent forward
fixpoint and covers mutation of caller-owned state. See
[ADR 0409](adr/0409-bc2cpp-dataflow-query-cache.md) for performance measurements.

The independent forward oracle in `bytecode_ir_dataflow_check.rb` shares
frozen definition sets between states, copying only sets that grow at a join.
It also keeps each pending instruction in the work queue once. A local
CRuby 3.4.9/YJIT straight-line benchmark with 4,096 instructions and 130
registers fell from 0.59 seconds to 0.09 seconds for the forward oracle alone;
all instruction/register states matched the earlier oracle. Backward-query
cost and the optional whole-tree check's total duration are separate costs.


### Mutation checks run off pull requests

`scripts/ci/timed_checks.rb` drops every `*_mutation_check.rb` command and strips
`*_MUTANTS=1` switches when `CI_SKIP_MUTANTS=1`, so a run keeps each shard's fixture
checks but not the mutant rebuilds. The shard jobs ran with that set on pull
requests; now that they run only in `bc2cpp-nightly.yml` ("Nightly bc2cpp" above),
nothing sets it and every nightly or manual run includes the mutants. The timing
estimates in the shard table include them.

### Device jobs run on a pull request only for their own files

`android` (with `android-smoke`), `maix` (with `maix-smoke`) and `nano7-qemu` build or emulate one
device target each. On a `pull_request` run they are skipped unless the `changes` job's filter for
that device matched; a push to `master`, a merge-queue run and a manual dispatch always run them.
The smoke jobs need their build job, so they are skipped with it. `wasm` is not gated and still runs
on every pull request, and `psp` keeps its own filter (it runs only when `app/psp/**` or the workflow
changed, and not on other pushes).

| Filter | Files that count as related |
| --- | --- |
| `android` | `app/android/**`, `scripts/android_smoke_check.bash`, `CMakeLists.txt`, `cmake/**`, `build_config.rb`, the workflow |
| `maix` | `app/maix/**`, `app/shared/**`, `scripts/maix/**`, `scripts/gen/maix-hello-game.rb`, `build_config.rb`, the workflow |
| `nano7` | `app/nano7/**`, `app/shared/**`, `scripts/nano7/**`, `scripts/export_nano7_map*.rb`, `scripts/stage_nano7_walk_app.bash`, `scripts/download/nepheshel.bash`, the workflow |

`build_config.rb` holds each device's cross-build definition, so a change to it runs the Android and
Maix jobs. Shared engine code (`src/`, the `mruby-*` gems) is not in any list: a pull request that
changes only that skips these jobs, and the push to `master` after the merge runs them. A device
regression from shared code therefore shows up on `master`, not on the pull request. To check a branch
earlier, use `workflow_dispatch` on it, or add the path to the filter.

### Splitting long shards

`hot-only` ran its two ~15 minute reviewed-set checks back to back, so
`hot-proven-miss` now runs `bc2cpp_proven_miss_check`. `coverage` takes the three
slowest checks out of `fast` (`bc2cpp_coverage_check`, the optcarrot coverage
check and `rescue_shadow`). Timings come from the "Check timings" job summary.

### Width shards

The `int32` variant is split into `int32-a` and `int32-b` (both build the same
32-bit libmruby via the matrix `build:` field). Once that libmruby is built, each
leg runs its checks in a `ci:parallel` group of three, since they only read it:
`int32-a` took 45.8 minutes serially and 18.1 in the group (local 4-core run,
docs/bc2cpp-ci-duration-profile.md). Add new 32-bit legs to whichever is shorter,
and keep them out of a group if they build a libmruby of their own.

### Check shards

`bc2cpp-checks` (in `bc2cpp-nightly.yml`) is a matrix; each shard is its own job with a 45 minute
timeout, and no other job or setting names a shard, so renaming or adding one touches
neither the `bc2cpp` check nor branch protection. Every check is listed in exactly one shard.
Keep each shard under about 25 minutes so one more check does not reach the
timeout; raise the timeout only as a last resort.

The RPG2k host checks (`rpg2k_logic_check.rb`, `rpg2k_scene_check.rb`,
`rpg2k_render_check.rb`) run in the `ruby-checks` job's `RPG2k game-logic checks`
step, not in a bc2cpp shard. The save-format check
(`rpg2k_lsd_authoritative_check.rb`, ADR 0395) runs in that same step: the
engine's `.lsd` save must load back field for field against the live state, and the
save-slot policy (the `.lsd` alone, old `.mrb` saves not read, a failed write
failing the save; docs/adr/0399) is tested there too. So are the typed-save checks
(`lcf_save_typed_check.rb`, which also fails when the generated
`save_typed_accessors.rb` is stale, and `rpg2k_lsd_adversarial_check.rb`, ADR 0400:
a save this engine did not write loads, or is an empty slot with the reason logged,
and truncated or corrupted saves never crash).

The compiled-versus-interpreted fixtures that need a full-core mruby are split
three ways, because each step takes minutes and one shard had reached the
timeout (a run of the old single `core-mrbtest` shard took about 43 minutes):

| Shard | Checks | Approx. |
| --- | --- | --- |
| `core-mrbtest` | block/yield-free/exact-receiver (+ `core_body_exact` and `core_singleton_audit`, ADR 0359, about 1 min)/return-class, `step_inline`, `define_method_sites`, `resumable`, `io_puts_model`, `fixnum_overflow`, `loop_flow_position` (ADR 0398), mruby's own suites | about 25 min |
| `full-core-numeric` | `numeric_slow` (ADR 0292, 454 s in a recent run), `index_closed` (ADR 0365, about 2 min): split from `core-mrbtest`, whose checks plus setup had reached its 45 minute timeout | est. 10 min |
| `numeric-direct` | `eqq_direct` (ADR 0293) and `tuple_return` (ADR 0311), moved out of `full-core-numeric` so `numeric_slow` runs alone there | see the timing table |
| `core-flow` | `exact_receiver_flow` (ADR 0301) | see the timing table |
| `core-flow-mutants` | `loop_flow_position` with `LFP_MUTANTS=1` (ADR 0398, four mutants), `exact_receiver_flow_mutation_check` (ADR 0301, eight mutants) and `computed_send` with `CSEND_MUTANTS=1` (ADR 0303), moved out of `core-flow` | see the timing table |
| `core-tables` | `frozen_tables` and its mutation check (ADR 0306) | see the timing table |
| `call-results` | `call_results` and its mutation check (ADR 0309; its 32-bit leg runs in `bc2cpp-width (int32-a)` or `(int32-b)`) | see the timing table |
| `native-wrappers` | `exact_native_wrappers` (ADR 0307) and its eight mutants | 5 min |
| `core-mutants` | `unlisted_class_call` with `UCC_MUTANTS=1` (seven mutant rebuilds) | 23 min |
| `block-arm-reach` | `block_arm_reach` with `BR_MUTANTS=1` (ADR 0310: six mruby builds, eight generator mutants) | 10 min (local, 4 cores) |
| `escape-analysis` | `escape_analysis` (unit, generated code, six mruby builds) and its mutation check (ADR 0316: eighteen mutants and a control) | est. 12 min (local: 6 min + 2 min) |
| `core-exact-direct` | `core_exact_direct` with `CX_MUTANTS=1` (ADR 0314: four mruby builds each run compiled and interpreted, nine generator mutants and a control) | 15 min (4 cores) |
| `captured-locals` | `captured_local_class` (generated code, full-core and core-only runs) and its mutation check (ADR 0308) | est. 15 min |
| `constructor-pools` | `constructor_pools` (generated code, full-core and core-only runs) and its mutation check, 13 mutants plus a control (ADR 0313); the 32-bit run is in `bc2cpp-width (int32-a)` or `(int32-b)` | est. 15 min |
| `numeric-constants` | `numeric_constants` (generated code with fifteen withdrawal worlds, full-core and core-only runs) and its mutation check, 16 mutants plus a control (ADR 0318; the mutation check ran 12 min locally with three jobs); the 32-bit run is in `bc2cpp-width (int32-a)` or `(int32-b)` | est. 20 min |
| `native-class-arms` | `native_class_arms` (generated code with sixteen withdrawal worlds, full-core and core-only runs over the base fixture, the compiled core and the method_missing, module and reopened-Hash worlds) and its mutation check, 13 mutants plus a control, mutants stop at the first matching FAIL line (ADR 0323), then `native_arm_cover` and its 3 mutants (ADR 0384); the 32-bit run is in `bc2cpp-width (int32-a)` or `(int32-b)` | est. 20 min |
| `numeric-intervals` | `numeric_intervals` (generated code with five withdrawal worlds and both kill switches, full-core and core-only runs) and its mutation check, 9 mutants plus a control (ADR 0326); the 32-bit run is in `bc2cpp-width (int32-a)` or `(int32-b)` | est. 10 min |
| `setter-pools` | `setter_pools` (the native store audit, generated code with the withdrawal worlds and three kill switches, a full-core run interpreted against compiled including the loud outside-setter and composed-name failures) and `aliased_names` (ADR 0370; its mutation check, eleven mutants: `setter_pools_mutation_check`) | est. 6 min |
| `type-check` | `type_check` (ADR 0412: the report front-end on a hand-written facts file, then fixture analyses: contradictions with exact text and file:line, ignored annotation tokens, inferred types and reason buckets, the by-name send ranking, byte-identical C++ with the facts on) and its mutation check, 18 mutants (11 front-end mutants need no mruby build) | est. 10 min |
| `rbs-signatures` | `rbs_signatures` (ADR 0413: the RBS subset and its located errors without MRBC; fixtures for located contradictions, stale and miscounted signatures, signature == comment C++, comment wins, build abort) and its mutation check, 13 mutants (5 loader mutants need no mruby build) | est. 10 min |
| `emit-rbs` | `emit_rbs` (ADR 0414: emitted RBS text on a hand-written facts file; a fixture round trip: emit, read back as signatures, nothing reported, a wrong edit is a located TC1001) and its mutation check, 12 mutants (11 need no mruby build) | est. 4 min |
| `entry-specialize` | `entry_specialize` (ADR 0380: generated code with the gate off and on, the identity clone, the refused shapes and worlds; a full-core run of every guard hit and miss against the interpreter) and its mutation check, 16 mutants | est. 8 min |
| `call-facts` | the non-mutation checks, with the first command (`call_facts`: generated code with ten withdrawal worlds, full-core and core-only runs, ADR 0317) alone because it builds `BC2CPP_FULL_BUILD_DIR`, then the rest as one `ci:parallel` group of three: `block_send_report` (ADR 0325, generated code only, 15 s), `dead_arm_report` (ADR 0330, generated code only, 15 s), `receiver_proof_report` (ADR 0331, generated code only, 30 s), `native_ivar_scopes` (ADR 0332, source audit, withdrawal worlds, full-core/core-only parity for Window/Sprite/Plane/Tilemap and subclasses, ADR 0337 bitmap setter families), `native_setter_report` (ADR 0337, byte-identical code, input masks, mentions and incomplete caller coverage), `native_class_results` (ADR 0333, pinned-source audit, mixed Ruby/native returns, withdrawal worlds, full-core/core-only parity), `native_string_results` (ADR 0334, linked native and Struct alias audits, generated withdrawal cases, full-core/core-only parity), `native_collection_results` (ADR 0335, copy/collection source and helper audits, override withdrawal, full-core/core-only parity), `native_array_transforms` (ADR 0336, name-wide allocation contracts, File.join subclass boundary, source/helper audits, full-core parity), `core_ruby_results` (ADR 0338, actual core bytecode, aliases, block exit/override/captured-write refusals, full-core parity), `enumerator_wrappers` (ADR 0350), `core_compiled_cmp` (ADR 0371) and `zero_direct` (ADR 0374); the mutation checks are in `call-facts-mutants-a` and `call-facts-mutants-b`; the 32-bit runs are in `bc2cpp-width (int32-a)` or `(int32-b)` | see the timing table (about 1988 s of commands in sequence on 4 cores, less through the group) |
| `call-facts-mutants-a` | the mutation checks `core_ruby_results` (ten mutants plus a control, ADR 0338; 572 s), `call_facts` (ten mutants plus a control, ADR 0317; 382 s, builds its mutant trees in `.mutants/`), `native_collection_results` (seven mutants plus a control, ADR 0335; 49 s) and `enumerator_wrappers` (ADR 0350; 10 s), run one after another | about 17 min (1013 s on 4 cores) |
| `call-facts-mutants-b` | the mutation checks `native_string_results` (ten mutants plus a control, ADR 0334; 190 s), `zero_direct` (ADR 0374; 164 s), `native_class_results` (eight mutants plus a control, ADR 0333; 134 s), `core_compiled_cmp` (four mutants, ADR 0371; 114 s), `native_ivar_scopes` (eleven mutants plus a control, ADR 0332/0337; 107 s) and `native_array_transforms` (seven mutants plus a control, ADR 0336; 98 s), run one after another | about 13 min (806 s on 4 cores) |
| `class-narrowing` | `class_narrowing` (generated code for every narrowing form, the negatives and twenty-one withdrawal worlds, full-core and core-only runs, the rogue-subclass guard violation) and its mutation check (ADR 0375); the 32-bit run is in `bc2cpp-width (int32-a)` | est. 14 min |
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

The Optcarrot runner now defaults to the toolchain's optimized release build
(`-O3` with GCC), for both the interpreter and generated C++. Set
`OPTCARROT_DEBUG=1` to reproduce the earlier `enable_debug` configuration
(`-O0`, `MRB_DEBUG`). The console and job summary identify the mode. Release,
debug and profiling builds use separate target directories, and the generated
gem is rebuilt on every invocation to prevent stale compiler output from
affecting measurements. Historical timings above predate this default change.

The Optcarrot shard also checks all 256 specialized opcode arms and strict-world
source validation, then runs the combined `OPTCARROT_STATIC_DISPATCH=1`
`OPTCARROT_CLOSED_WORLD=1` experiment against the same checksum benchmark.

`bc2cpp-width (int32-a)` or `(int32-b)` took 9 min. `core-flow` was the long pole of the whole
workflow; its mutation checks now run in `core-flow-mutants`.

### Reading the timing table

Every `bc2cpp-checks` and `bc2cpp-width` job runs its `checks:` block through
`scripts/ci/timed_checks.rb`, which leaves the commands exactly as written (same
shell, same order, `set -e` still stops at the first failure) and brackets each
with a stopwatch. When the step ends, pass or fail, it prints

```
== check timings (seconds  command), slowest first
    812.4  CSEND_MUTANTS=1 BC2CPP_MRUBY_CORE="$core" ... ruby scripts/bc2cpp/computed_send_check.rb
    ...
      0.1  FAILED  MRBC="$mrbc" ruby scripts/bc2cpp_foo_check.rb
   1543.9  total
```

at the end of the step log and in the job summary ("Check timings"). The
command that failed is marked `FAILED`, with the time it ran before failing;
commands after it never ran and are not listed. Lines that only set variables
(`width=...`, `export ...`) are not timed, comments are dropped. Use the table
to decide where a new check goes: put it in the shard with the most slack, and
keep each shard's total under the budget above (commands in a `ci:parallel` group overlap, so their sum is more than the wall time). `ruby scripts/ci/helpers_check.rb`
(in `ruby-checks`) covers the wrapper.

The binary decoder shares each opcode's debug-file lookup between filename
and line decoding, and scans multi-file records without allocating an
enumerator. A local 125,640-instruction world decoded in about 0.87 seconds
instead of 0.95 seconds, with roughly one million fewer allocations.
`scripts/bc2cpp/binary_loader_check.rb` checks file boundaries, absent records,
duplicate start positions and reverse queries, then compares full instruction
and line metadata with mrbc output.

### Decoded tree cache

Manual nightly runs offer a `decoded_tree_cache` comparison input, off by
default. Enabling it sets `BC2CPP_IREP_CACHE_DIR` under `runner.temp`.
Repeated repository-source worlds reuse their initial
decoded RITE tree; every caller restores private objects before analysis.
Temporary fixture compilations bypass it. Canonical filenames let the three
engine gems share one world rather than treating their `gem/..` roots as
separate inputs.

The key includes exact bytecode, decoder code, Ruby/Marshal identity and
EXT-prefix mode. Locks prevent duplicate concurrent decoding, and checksummed
snapshots are published atomically. Corruption is logged before rebuilding;
decoder errors still fail. The first cache fill adds serialization work, and
later identical worlds avoid decoding. A local three-process comparison took
14.06 seconds uncached, 15.11 seconds cold and 12.96 seconds warm, so regular
host builds and scheduled checks keep it disabled. Set the variable for local
comparisons, or unset it to disable reuse.
See [ADR 0411](adr/0411-bc2cpp-decoded-tree-cache.md) for measurements and checks.

### Compiler cache (sccache)

`scripts/bc2cpp/cxx.rb` is where the checks start the C++ compiler
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

### Test mruby builds execute prerequisites in parallel

The bc2cpp fixture, width and core-test builders pass `rake -m -jN`, with
`N` capped at 16. `-j` alone limits the thread pool but leaves mruby's ordinary
task prerequisites serial; `-m` enables their concurrent execution, as in the
main host build. Existing artifact checks and error handling still apply.
[ADR 0410](adr/0410-bc2cpp-test-rake-multitask.md) records a clean-build
comparison. For a local concurrency check, add `RAKEOPT=--job-stats` and inspect
the builder's saved log for `Total threads in play`.

### Scan cache (ADR 0415)

Every closed-world generator run is a new process that scans the same mruby and gem C sources. With
`BC2CPP_SCAN_CACHE_DIR` set, three of those scans (`NativeExpressionDevirt.analyze`,
`analyze_exact_class_expressions` and `outside_world_tokens`) are stored under a digest of the scanner sources and
of the files they read, and loaded by the next process. The nightly workflow sets it per job to
`$RUNNER_TEMP/bc2cpp-scan-cache`, so the first check of a job fills it and the rest of the job (a `ci:parallel`
group included) reads it. `numeric_slow` takes 316 s with it against 398 s without. Without the variable nothing
is read or written. `scripts/bc2cpp/scan_cache_check.rb` (in `ruby-checks`) covers it; the entries are Marshal
dumps, so point the variable only at a directory you own.

### Mutant pool

The mutation checks run one subprocess per mutant, each independent. Through
`scripts/bc2cpp/mutant_pool.rb` they run up to `BC2CPP_JOBS` at a time (default
the core count, at most 4; `1` is the old serial order) and report in input
order, so the log and every `ok`/`FAIL` line read as before. Memory is small
for the generated-code mutants (the generator stays under 100 MB); a mutant that
also compiles and runs a fixture is the larger one. Two behaviours worth
knowing:

- A mutant is stopped at the first `FAIL` line that already proves it caught
  (for the checks with an expected label, the first line matching it). Every
  check prints `FAIL` only together with a nonzero exit, so the verdict is the
  same; the run just does not finish the checks after the one that fails. A
  mutant that survives runs to the end, as before. Ruby children with a
  stop matcher preload `scripts/bc2cpp/unbuffered_stdout.rb`, so a failure is
  visible through the pipe before subsequent work starts. Controls without a
  matcher keep their normal buffering, and Ruby subprocesses do not inherit
  the preload. A local one-second delayed-work reproduction stops in about
  0.04 seconds instead of 1.03 seconds; this is a latency check, not a measured
  nightly-workflow speedup.
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

### Parallel groups

A shard can run independent checks at the same time. Put the commands between two
comment lines in the `checks:` block:

```
# ci:parallel begin 3
MRBC="$mrbc" ruby scripts/bc2cpp/a_check.rb
MRBC="$mrbc" ruby scripts/bc2cpp/b_check.rb
# ci:parallel end
```

`scripts/ci/timed_checks.rb` runs them at most N at a time (without a number, `CI_PARALLEL_JOBS`,
then 3). The markers are comments, so a block that is not run through the script runs the same
commands in order. Each command runs in a subshell of the step, so it sees the step's variables
(`$mrbc`, `$core`) but cannot set one for later commands; assigning a variable inside a group is
refused when the script is generated. Output goes to a log per command and is printed in input
order after the group, so a failing command's output is shown in full and the others are folded
(`::group::`). The step fails with the first failed command's status, after the rest of the group
has finished; the commands after a failed group do not run.

What may go in a group: commands that share no build state. A command that *builds* the
full-core mruby into `BC2CPP_FULL_BUILD_DIR` stays outside the group and runs first, alone, because
two builders would race on one directory. A command after it only reads that build
(`full_or_build` returns an existing `lib/libmruby.a` before it writes anything), so the rest may
share it in a group. The four mutation checks that build their mutant trees in the repository's
`.mutants/` directory (`call_facts_mutation`, `class_narrowing_mutation`, `native_arm_cover_mutation`,
`native_class_arms_mutation`) must not run side by side: each removes `.mutants/` when it finds it
empty, so one can delete the directory under another. The mutant pool already uses the cores, so a
group is for shards made of single-process scripts. A group adds CPU and memory load, so keep N at 3
on the 4-vCPU runner: `embedded_ivar_access_check` alone uses about 2.5 cores.

Groups in use: `registrations`, both width legs, and `call-facts` (its first command builds the
full core, the rest of the non-mutation checks run as a group). The ten `call-facts` mutation checks are not in
a group: they are split over the shards `call-facts-mutants-a` and `call-facts-mutants-b` and run in sequence,
because each already runs a four-wide mutant pool and `call_facts_mutation` is the only one of them that uses
`.mutants/`. Measured on a 4-core machine for the `registrations` shard:
its four scripts took 211 s in sequence and 118 s through a group, the longest single script. The
width leg `int32-a` took 2749 s in sequence and 1085 s in a group (same 1329 passing checks). The
timing table's `total` is the sum of the command times, so for a group it is more than the wall
time of the step. docs/bc2cpp-ci-duration-profile.md has the measurements.

### Width builds (ADR 0300)

The Emscripten, Wio and PSP targets use a 32-bit `mrb_int`. Every shipped target
links mruby-bigint (`build_config.rb`), so there is no no-bigint variant. `bc2cpp-width` re-runs the compiled-versus-interpreted
checks on a libmruby built by `scripts/bc2cpp/width_build.rb`:

| Variant | Build | Checks |
| --- | --- | --- |
| `int32` | full-core, `-DMRB_32BIT -DMRB_INT32` (31-bit Fixnums) | `numeric_slow`, `fixnum_overflow`, `step_inline`, `lcf_row_flow`, `call_results` |
| `int32` | full-core, `-DMRB_32BIT -DMRB_INT32` (31-bit Fixnums) | `numeric_slow`, `index_closed`, `fixnum_overflow`, `step_inline`, `lcf_row_flow`, `tuple_return`, `zero_direct` |

The 32-bit build is the 64-bit host with the targets' arithmetic defines, so it
does not exercise 32-bit pointers. To run a variant locally, after the mruby
patch chain has been applied (any cmake build does it; the numeric-slow check
links `mrb_int_mod_impl` and friends from `patches/mruby-expose-misc-bodies.patch`,
ADR 0367, so a libmruby built from an unpatched tree fails to link):

```bash
ruby scripts/bc2cpp/width_build.rb int32 /tmp/w32
BC2CPP_MRUBY_FULL32=/tmp/w32/host BC2CPP_MRBC32=/tmp/w32/host/bin/mrbc \
  MRBC=<64-bit host mrbc> ruby scripts/bc2cpp/numeric_slow_check.rb
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

The `core-flow` shard also runs `bc2cpp_zero_direct_check.rb` and its mutation check (ADR 0374); the `int32`
width legs run the same check against their own libmruby. A closed world that compiles
mruby's own Ruby has `bc2cpp_slow_zero` call the compiled `Numeric#zero?` for every Numeric that is not a
Float, raise the `File.zero?` argument error for those class objects, and keep the NoMethodError proof for
the rest. The check covers the generated code, twelve negative worlds (reopened, aliased, included,
prepended, singleton or class-level definers, a computed installer, `method_missing`, a `==` that may
yield, a build without mruby-numeric-ext or mruby-io, an open world, no core compile, both kill switches)
and a run of the helper against the real `zero?` (values, error class and message, user `==` calls, the
by-name call count) at every width, in the closed world and in four worlds that must keep the by-name helper.

### Loop flow positions (ADR 0398)

The `core-mrbtest` shard runs `bc2cpp_loop_flow_position_check.rb`: four closed-world worlds (a method local read in an
inlined `each` takes the method's flow at the loop, refused for a reassigned element and for a local the body writes,
no set for an argument receiver) and the switch-off control, which must read and refuse no position. The
`core-flow-mutants` shard runs the same check with `LFP_MUTANTS=1`: four copies of `tools/bc2cpp` with one guard
removed or a wrong position read, each of which must fail. The check needs only `MRBC`; it runs no mruby build.
