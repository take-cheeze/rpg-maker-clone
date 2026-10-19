# Continuous integration

[`.github/workflows/build.yml`](../.github/workflows/build.yml) is the CI
workflow. It runs on pull requests to `master`, pushes to `master`, merge-queue
runs, manual dispatch and (for the Cloudflare preview only) `/preview` comments.
There is no separate nightly workflow: the bc2cpp checks that ran only there were removed.
Deployment is covered in [deploy.md](deploy.md).

## Native cache restore scheduling

The native build restores its Nix, RTP, Wine prefix and test-game caches as
foreground steps after checkout. Their `hashFiles` keys need the checked-out
flake, installer scripts and sample assets; running before checkout produces
empty hashes and prefix-only keys such as `nix-Linux-`.

JavaScript actions can read `GITHUB_EVENT_PATH` during
initialization, while runner 2.337.0 rewrites that shared event file before
every step. Starting another step while a cache action initializes can expose
an empty event payload and fail with `SyntaxError: Unexpected end of JSON
input` before the build begins. The runner's
[`WriteWebhookPayload`](https://github.com/actions/runner/blob/v2.337.0/src/Runner.Worker/ExecutionContext.cs)
uses `File.WriteAllText`, and
[`ActionRunner`](https://github.com/actions/runner/blob/v2.337.0/src/Runner.Worker/ActionRunner.cs)
calls it before each action.

Cache restore timeouts still report stalled backends. Independent shell
validation and asset downloads continue as background steps; their existing
barriers still propagate failures before the build or link consumes them.

## Native SDL probes

On Linux, `exe_open`, `render_probe`, `audio_probe` and `error_dump` use reserved
Xvfb displays and set `SDL_VIDEODRIVER=x11` through CTest. This ensures SDL uses
the virtual display even when the parent environment describes a Wayland
session. The audio probe retains `SDL_AUDIODRIVER=dummy`. Normal desktop runs
continue to select their backend through SDL's usual configuration.

## bc2cpp gate

bc2cpp compiles closed-world programs only (ADR 0466), so `bc2cpp-build` builds a closed world:
`build_config.rb`'s `closed` build (`MRUBY_TARGET=closed`, `scripts/bc2cpp/closed_build.bash`)
with `RPGMAKER_BC2CPP=1`. It is the maix closed world compiled by the runner's own compiler:
`single_format_only` (RPG2000/2003 only), maix's gem set (no `mruby-dir`, `mruby-compiler`,
maix's mruby-io HAL) and maix's host sources as bc2cpp's native input. The four `*-compiled`
gems are generated in that closed world and compiled into its `libmruby.a`, and the job then
runs the type check (`scripts/bc2cpp/type_check.rb`) with that build's host `mrbc`.

The build is native because bc2cpp's generated C++ lowers block `break`, non-local `return`
and `raise` with real C++ throw/catch, which needs mruby's C++-exception mode
(`MRB_USE_CXX_EXCEPTION`). The `maix` cross library is compiled with `-fno-exceptions` (the
Kendryte link drops `.eh_frame`, so nothing can unwind on the device), so the generated code
does not compile there. The job covers generation and compilation of the generated code with
exceptions; it does not cover the RISC-V cross-compile, which the `maix` job builds without
bc2cpp. It needs no PlatformIO or cross toolchain.
The desktop `host` build loads Ruby at runtime and never carries the compiled gems.

The status check `bc2cpp` in `build.yml` reports `bc2cpp-build` (skipped on purpose for
a docs-only change). Require `bc2cpp`.

### bc2cpp job setup and check scheduling

The gate uses `nix develop .#bc2cpp`, a host tools shell without the game
shell's Wine, Emscripten or graphics dependencies. Its Nix store cache has a
separate `nix-bc2cpp-` prefix. The environment export helper accepts this
installable as its optional first argument; other jobs keep the default shell.

After compiling and verifying the closed-world archive, the job prepares the
full-core fixture library once. Its exact cache key includes the pinned Nix
toolchain, mruby and stringio revisions, build helpers and mruby patches.
`BC2CPP_MRUBY_FULL` makes subsequent fixtures read the prepared library.
The existing timed-check wrapper runs every check with at most two commands
at once, retaining command logs, failure status and a timing table in the job
summary. Base-section verification also writes the freshly generated base RBS
under `build-closed-bc2cpp/base_rbs`, replacing a second generation pass.
`base_section_check.rb --output DIR CLOSED_BUILD_DIR` requires an absent or
empty output directory. See [ADR 0510](adr/0510-bc2cpp-ci-bounded-checks.md).

### Constant typing fixtures

`scripts/bc2cpp/constant_typing_check.rb` combines the frozen-container,
Hash-merge, Array-sum and integer-arithmetic checks. It runs compatible positive
fixtures as one program and shares the `Object#freeze` withdrawal program.
Other redefinitions, prepends and unresolved mixins remain separate programs;
the suite also checks integer intervals independently in process. All original
assertions retain their individual labels. This reduces end-to-end analyses
from 16 to 13. Each fixture uses an empty signature directory and requires a
successful type-check exit status, so unrelated engine declarations cannot hide
an analysis failure. See [ADR 0511](adr/0511-constant-typing-check-suite.md).

### Constant proof fixtures

`scripts/bc2cpp/constant_proofs_check.rb` groups the declared-Array-sum,
declared-join and lexical-join checks under one temporary-program compiler and
assertion reporter. Its sections cover declaration/report agreement, method
replacement refusals, frozen and boolean values across joins, and lexical
holders, superclasses and mixins. Every source fixture is compiled separately;
redefinitions and repeated constant names cannot affect another fixture.
CI invokes the suite once, and the coverage reporter registers it once in place
of the former lexical/declared join entries. Set `MRBC` to a host compiler to
run its fixtures; without it the suite reports a skip, as its predecessors did.

### Superseded runs

A push to a pull request cancels the run still going for that PR's previous
commit (workflow-level `concurrency`, keyed on the PR number). Master pushes,
merge-queue runs, manual dispatches and `/preview` comments use a per-run group
and are never cancelled.

### Profiling bc2cpp on a desktop host

`bc2cpp` is closed-world only, and CI profiles it on wio's world. For local
profiling on a machine with a display, set
`RPGMAKER_BC2CPP_CLOSED_WORLD_HOST=1` (ADR 0428) to build `host` as a sealed
RPG2000/2003-only world, so `bc2cpp` runs there without a cross toolchain.
This is test-only and cannot play XP/VX/Wolf/MV or arbitrary runtime Ruby.

### Host Ruby uses YJIT for bc2cpp

`bc2cpp-build` sets `RUBY_YJIT_ENABLE=1` for the
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

### Scan cache (ADRs 0415, 0462)

Every closed-world generator run is a new process that scans the same mruby and gem C sources. The native-source
scans are stored under a digest of the scanner sources, the Ruby version and the files they read, and loaded by the
next process: `NativeExpressionDevirt.analyze`, `analyze_exact_class_expressions`, `outside_world_tokens`, the facts
of `ClosedWorld#scan_native` (`closed_world.native`), the class registrations
(`native_expression_devirt.class_registrations`, under `CallFacts::Answers#native_scan`) and the per-file
registrations of `NativeDirect` (`native_direct.file_registrations`). The last three return plain data, and the
instance state they used to fill is rebuilt by the caller from it. The cache is always on, with no environment
switch: entries live in the checkout's git-ignored `build/bc2cpp-cache`, so the first generator run of a job fills it
and every later run of that job (a `ci:parallel` group included) reads it. A checkout that is not cleaned keeps it
between runs; that is safe because every key holds the content digests. Any cache fault (an unreadable entry, an
entry stored under another key, a value or directory that cannot be stored, a cached scan that reads `ENV`) stops the
run with a `ScanCache::Error`; it is never recomputed past. `scripts/bc2cpp/scan_cache_check.rb` (in `ruby-checks`)
covers it; a check that needs its own directory sets `ScanCache.directory_override` from Ruby. The entries are
Marshal dumps, so the checkout must be a directory only you write.

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
`ci_helpers_check.rb` covers the pool itself. `frozen_slot_check.rb` (ADR 0425) runs its host section in `build.yml` and
its MRBC section in the `core-tables` shard of `bc2cpp-nightly.yml`.

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

A command that appends to the job summary (`$GITHUB_STEP_SUMMARY`) shares that file with the other
commands, so it joins a group only with a file of its own. Prefix it with `GITHUB_STEP_SUMMARY=<file>`
and add a line after `# ci:parallel end` that appends the files to the summary in input order. The
prefix works because a group runs each command with `eval` in its own subshell. If the group fails,
the appending line does not run, so the summaries of that shard are missing and the failing command's
output is in the log.

Groups in use: `registrations`, both width legs, `call-facts` (its first command builds the
full core, the rest of the non-mutation checks run as a group) and `coverage` (the two job-summary
reports, each with its own file, and the rescue shadow check; see the summary rule above). The ten `call-facts` mutation checks are not in
a group: they are split over the shards `call-facts-mutants-a` and `call-facts-mutants-b` and run in sequence,
because each already runs a four-wide mutant pool and `call_facts_mutation` is the only one of them that uses
`.mutants/`. Measured on a 4-core machine for the `registrations` shard:
its four scripts took 211 s in sequence and 118 s through a group, the longest single script. The
width leg `int32-a` took 2749 s in sequence and 1085 s in a group (same 1329 passing checks). The
timing table's `total` is the sum of the command times, so for a group it is more than the wall
time of the step. docs/bc2cpp-ci-duration-profile.md has the measurements.

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
yield, `method_missing`, a singleton, a build without mruby-hash-ext, no core
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
covers the closed world. See ADR 0358 and
[bc2cpp-native-int-guards](bc2cpp-native-int-guards.md).

### The zero? helper through compiled core

The `core-flow` shard also runs `bc2cpp_zero_direct_check.rb` and its mutation check (ADR 0374); the `int32`
width legs run the same check against their own libmruby. A closed world that compiles
mruby's own Ruby has `bc2cpp_slow_zero` call the compiled `Numeric#zero?` for every Numeric that is not a
Float, raise the `File.zero?` argument error for those class objects, and keep the NoMethodError proof for
the rest. The check covers the generated code, twelve negative worlds (reopened, aliased, included,
prepended, singleton or class-level definers, a computed installer, `method_missing`, a `==` that may
yield, a build without mruby-numeric-ext or mruby-io, no core compile, both kill switches)
and a run of the helper against the real `zero?` (values, error class and message, user `==` calls, the
by-name call count) at every width, in the closed world and in four worlds that must keep the by-name helper.

### Loop flow positions (ADR 0398)

The `core-mrbtest` shard runs `bc2cpp_loop_flow_position_check.rb`: four closed-world worlds (a method local read in an
inlined `each` takes the method's flow at the loop, refused for a reassigned element and for a local the body writes,
no set for an argument receiver) and the switch-off control, which must read and refuse no position. The
`core-flow-mutants` shard runs the same check with `LFP_MUTANTS=1`: four copies of `tools/bc2cpp` with one guard
removed or a wrong position read, each of which must fail. The check needs only `MRBC`; it runs no mruby build.

### RGSS::Tts in limited builds (ADR 0417)

`scripts/tts_limited_check.rb` (the `ruby-checks` job, no submodules needed) evaluates the real `mruby-rgss` and
`mruby-rpg2k` `mrbgem.rake` files for every build name and fails unless `tts.cxx`, `RGSS_NO_TTS` and the
`speak_message` source (`map_tts.rb` against `map_tts_off.rb`) are exactly what `tools/rgss_tts_config.rb` says, the
bc2cpp source sets (`compiled_gems.rb`) agree, and `speak_message` behaves as before where Tts exists. With `--bc2cpp`
(the `fast` nightly shard, needs `MRBC`) it also runs the wio closed world for `mruby-rpg2k-compiled` and fails if the
generated C++ names Tts.

### IR block fixtures

`scripts/bc2cpp/ir_blocks_check.rb` runs capture provenance, RBS callback
binding, direct-yield protocols and reaching block operands in one Ruby process.
The case files in `scripts/bc2cpp/ir_blocks/` load into separate anonymous modules,
so helper methods cannot overwrite another case's helpers. Every mrbc fixture
keeps its original separate program and analysis; the suite shares loaded
libraries rather than combining closed worlds. Capture and callback host cases
run without `MRBC`; yield and operand fixtures report skips. `bc2cpp-build` sets
`MRBC` and runs every case, including the capture and yield fixtures previously
registered only with the host coverage reporter. See
[ADR 0512](adr/0512-ir-block-check-suite.md).
