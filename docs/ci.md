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
with `RPGMAKER_BC2CPP=1`. It is the sealed RPG2000/2003 desktop host's closed world, compiled by the
runner's own compiler: `single_format_only` (RPG2000/2003 only), the desktop host's gem set without
the XP/VX/Wolf/MV gems and without `mruby-onig` and `mruby-dir`, and the desktop `src/` tree as
bc2cpp's native input (`BC2CPP_CLOSED_WORLD_HOST_SRCS`). The four `*-compiled`
gems are generated in that closed world and compiled into its `libmruby.a`, and the job then
runs the type check (`scripts/bc2cpp/type_check.rb`) with that build's host `mrbc`.
The build compiles at `-O0`, so `closed_build.bash` drops Nix's `fortify` hardening flags for
its rake runs. glibc's `_FORTIFY_SOURCE` needs optimization and would otherwise warn on every
file. Nix's compiler wrapper appends its define after the command's flags, so a `-U` in
`build_config.rb` cannot undo it.

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
The existing timed-check wrapper runs every check with at most four commands
at once, retaining command logs, failure status and a timing table in the job
summary. The bc2cpp group starts longer checks first using recent CI timings,
leaving short checks to fill the final worker slots. Revisit the order after
large timing changes; see the [duration profile](bc2cpp-ci-duration-profile.md#6-pr-check-queue-order).
Base-section verification also writes the freshly generated base RBS
under `build-closed-bc2cpp/base_rbs`, replacing a second generation pass.
`base_section_check.rb --output DIR CLOSED_BUILD_DIR` requires an absent or
empty output directory. `base_section_regen_check.rb` is the host-only diff test for the
writer: fixture generator output, plus a round trip of the committed file that must reproduce it
byte for byte.
See [ADR 0510](adr/0510-bc2cpp-ci-bounded-checks.md).

### Constant typing fixtures

`scripts/bc2cpp/constant_typing_check.rb` combines the frozen-container,
Hash-merge, Array-sum and integer-arithmetic checks. It runs compatible positive
fixtures and the unknown merge receiver as one program, and shares the
`Object#freeze` withdrawal program. The unknown receiver adds no method definitions.
Other redefinitions, prepends and unresolved mixins remain separate programs;
the suite also checks integer intervals independently in process. All original
assertions retain their individual labels. This reduces end-to-end analyses
from 16 to 12. Each fixture uses an empty signature directory and requires a
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

### Check registration audit

`ruby scripts/ci/check_registry.rb` reads the coverage reporter's actual
`--list` output and the workflow's shell steps, including nested parallel
steps. It rejects references to deleted checks, duplicate invocations within
one job or the coverage list, and newly discovered bc2cpp checks without a
registration or an explanation in `scripts/ci/bc2cpp_check_policy.yml`.
A check may appear in both the host coverage runner and the compiler job;
these exercise different fixture capabilities.

The compiler job now also runs the context, argument, ivar, class-soundness,
numeric-root and block-protocol fixture sections that previously only had
host coverage registrations. The block-receiver proof requires MRBC too,
even though its source has no explicit environment guard. The registry check
requires these entrypoints in `bc2cpp-build`, where MRBC is prepared.
Eight previously unscheduled host checks run through the coverage reporter,
including the standalone argument-type suite. Its call-site index now imports
the numeric IR methods it uses instead of depending on a prior compiler load.

The policy records tiers and prerequisites for every active and deferred check.
Host-only passes and complete fixture coverage are reported separately. Existing
argument-driven utilities and larger runtime, mutation or whole-engine audits
retain explicit deferral reasons; this does not claim they run in ordinary CI.
Removed paths and scheduled deferrals must leave the inventory. See the
[tier and capability guide](bc2cpp-check-tiers.md) and
[ADR 0513](adr/0513-bc2cpp-check-registration-audit.md).

### Audit pins

bc2cpp trusts a few hand-audited native and foreign-Ruby files (`NativeIvarScopes::FILES`,
`NativeClassResults::FILES`, `ForeignStringResults::AUDITED`), each pinned by SHA-256. A file whose digest no
longer matches silently drops out of its audit, which is safe but withdraws every fact it backs: an edit of
`mruby-rgss/src/lib.cxx` or an mruby bump once turned off all native ivar scopes and the `to_s`/`split`/`bytes`
result facts with nothing failing. `scripts/bc2cpp/audit_pins_check.rb` fails on such a file instead. Re-read the
change against what the audit claims (the file's comment says which functions), then add the new digest; the
`NativeClassResults` tables accept a list, so the old digest can stay.

### Superseded runs

A push to a pull request cancels the run still going for that PR's previous
commit (workflow-level `concurrency`, keyed on the PR number). Master pushes,
merge-queue runs, manual dispatches and `/preview` comments use a per-run group
and are never cancelled.

### Profiling bc2cpp on a desktop host

`bc2cpp` is closed-world only, and CI builds the sealed RPG2000/2003 desktop host's closed world
(see the [bc2cpp gate](#bc2cpp-gate) above). The sealed host, built with the CMake option
`RPG2K_SEALED_HOST`, compiles out the `--script` loader, so it cannot play XP/VX/Wolf/MV or run
arbitrary runtime Ruby. The `RPGMAKER_BC2CPP_CLOSED_WORLD_HOST=1` switch that built `host` as a
sealed world has been removed.

### Behavioral installer fixtures

`define_method_check.rb` and `alias_method_check.rb` share the
`Bc2cppFixtureRuntime.registry_snapshot` setup: compile one temporary fixture,
build its registry, apply the check's explicit settle policy, then capture the
installed names. Every positive, refusal and withdrawal still has its own
program and registry. Generation, C++ drivers, mruby build discovery and runtime
output parsing already share `fixture_runtime.rb` with the owner-call and
constructor checks; their different runtime scenarios remain separate.

With a usable full-core library and C++ compiler, each installer/refusal world
runs whole-program analysis once, then uses the existing `--units` mechanism
(ADR 0464) to emit both unrestricted code-shape output and the runtime's exact
`ONLY_OWNERS` selection. The runtime unit's generated code, diagnostics and
bytecode stay in memory until that fixture runs. Different worlds never share
analysis, and core-only runs retain their separate core-source polyfill world.
There is no cache across invocations or changes to generator inputs.

### Block iterator fixtures

`block_iterator_direct_check.rb` retains its baseline generated C++, bytecode
and registration report through the runtime comparison, avoiding a second
identical closed-world generation. `BC2CPP_CXXFLAGS=-DMRB_USE_BIGINT` is still
applied when compiling the driver; that variable is consumed only by the C++
runtime helper, so it does not change generator inputs. Withdrawal worlds and
`BC2CPP_BLOCK_CORE_DIRECT=0` each retain their own generation. All iterator,
Fiber and GC scenarios still run in both interpreted and compiled VMs.

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
in [Ruby's YJIT manual](https://docs.ruby-lang.org/en/4.0/yjit/yjit_md.html).

The bc2cpp jobs run the Ruby that `flake.nix`'s `bc2cpp` dev shell provides (`ruby_4_0`,
currently 4.0.5). `nix develop .#bc2cpp -c ruby -e 'puts RUBY_DESCRIPTION'` shows it.
The version the measurements below used is named with each one.

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
CRuby 3.4.9/YJIT (measured before the bc2cpp jobs moved to Ruby 4.0) straight-line benchmark with 4,096 instructions and 130
registers fell from 0.59 seconds to 0.09 seconds for the forward oracle alone;
all instruction/register states matched the earlier oracle. Backward-query
cost and the optional whole-tree check's total duration are separate costs.


### Device jobs

`android` (with `android-smoke`), `maix` (with `maix-smoke`) and `psp` do not run on a
`pull_request`: a push to `master`, a merge-queue run and a manual dispatch run them (`psp` there
still only when `app/psp/**` or the workflow changed, as before). Their builds take long and a pull
request rarely touches a device, so a device regression shows up in the merge queue or on `master`.
To check a branch earlier, use `workflow_dispatch` on it. The smoke jobs need their build job, so
they are skipped with it. `wasm` still runs on every pull request.

`nano7-qemu` keeps its filter: on a pull request it runs only when its own files changed.

| Filter | Files that count as related |
| --- | --- |
| `nano7` | `app/nano7/**`, `app/shared/**`, `scripts/nano7/**`, `scripts/export_nano7_map*.rb`, `scripts/stage_nano7_walk_app.bash`, `scripts/download/nepheshel.bash`, the workflow |

### Compiler caching and shared mruby builds

`scripts/bc2cpp/cxx.rb` launches fixture C++ compilers and supplies `CC`/`CXX`
for fixture-library builds. It can use `BC2CPP_SCCACHE`, the CMake launcher or
`sccache` on `PATH`; `BC2CPP_SCCACHE=0` disables it. A cached compilation uses
`-c` followed by a separate link, with temporary source paths made relative.
Without a launcher, the compiler arguments pass through unchanged.

The native game job configures the action-provided sccache with writes limited
to master pushes. The dedicated bc2cpp shell does not require that service.
Instead, `bc2cpp-build` caches its full-core fixture library with an exact key
covering the Nix pin, contributing submodules, build helpers and patches.
`full_or_build` trusts an existing library, so callers reusing a build directory
must invalidate it when those inputs change. CI prepares it once before the
parallel group and exports `BC2CPP_MRUBY_FULL` to the fixture checks.

A fixture linked against that library is compiled with the library's own `-D`
flags, the `MRUBY_CFLAGS` of `lib/libmruby.flags.mak`
(`Bc2cppFixtureRuntime.library_defines`). The generated bigint arms sit under
`MRB_USE_BIGINT`, as a real build compiles them with the gem defines; without
the define a bigint operand took a helper's proven-dead fallback instead
(`scripts/bc2cpp/bigint_slow_arms_check.rb`).

The closed build uses `rake -m -j4`. The fixture-library builder uses `rake -m`
with a processor-based limit capped at 16; `-j` alone does not enable concurrent
ordinary Rake prerequisites. See [ADR 0410](adr/0410-bc2cpp-test-rake-multitask.md).

`base_section_check.rb` accepts `--jobs N` for its native preprocessing
workers; CI passes 4 (the runner fills out alongside the other parallel
checks). Local runs keep the default 2. If the step's timing table shows
contention instead of a speedup, revert CI to 2 — one flag.

The `binding_split.rb check` in `bc2cpp-build` reads cached libclang facts
(`--facts`) instead of running the extraction. `actions/cache` holds
`facts_<config>.json` keyed on the Nix pin, mruby/uni-algo revisions, RGSS
sources, repo headers, the extractor and the closed build's generated headers;
it deliberately excludes the classifier scripts, so a classifier-only change
still runs the check (fresh-or-identical facts, same verdict). A missing file
in the cache dir aborts with "re-run without --facts" rather than checking
against a partial cache. Staleness is handled by the key: any input change
misses and re-extracts. Inputs the key cannot see (system libclang headers via
`-isystem`) are pinned by `flake.*` through the same Nix toolchain.

### Scan cache (ADRs 0415, 0462)

Every closed-world generator run is a new process that scans the same mruby and gem C sources. The native-source
scans are stored under a digest of the scanner sources, the Ruby version and the files they read, and loaded by the
next process: `NativeExpressionDevirt.analyze`, `analyze_exact_class_expressions`, `outside_world_tokens`, the facts
of `ClosedWorld#scan_native` (`closed_world.native`), the class registrations
(`native_expression_devirt.class_registrations`, under `CallFacts::Answers#native_scan`), the per-file owner map of
`NativeOwnerMap.build` (`native_owner_map.file`) and the per-file registrations of `NativeDirect`
(`native_direct.file_registrations`). The last three return plain data, and the
instance state they used to fill is rebuilt by the caller from it. The cache is always on, with no environment
switch: entries live in the checkout's git-ignored `build/bc2cpp-cache`, so the first generator run of a job fills it
and every later run of that job (a `ci:parallel` group included) reads it. A checkout that is not cleaned keeps it
between runs; that is safe because every key holds the content digests. Any cache fault (an unreadable entry, an
entry stored under another key, a value or directory that cannot be stored, a cached scan that reads `ENV`) stops the
run with a `ScanCache::Error`; it is never recomputed past. `scripts/bc2cpp/scan_cache_check.rb` (in `ruby-checks`)
covers it; a check that needs its own directory sets `ScanCache.directory_override` from Ruby. The entries are
Marshal dumps, so the checkout must be a directory only you write.

### Mutant pool

`scripts/bc2cpp/mutant_pool.rb` runs independent mutant subprocesses with up to
`BC2CPP_JOBS` workers (processor count capped at four by default). Results and
logs appear in input order. A configured failure matcher stops a mutant after
its expected failure becomes visible; `scripts/ci/helpers_check.rb` tests
failure propagation and concurrency. A supplied `BC2CPP_FULL_BUILD_DIR` is
prepared before the pool begins so workers cannot build the same library.

`class_pools_mutation_check.rb` uses this helper. It is an explicitly deferred
mutation audit, rather than a check scheduled by a removed nightly workflow.
Its generator copies remain isolated from the checkout. Consult the
[check inventory](bc2cpp-check-tiers.md) before choosing an execution tier.

### Parallel groups

`scripts/ci/timed_checks.rb` accepts independent shell commands between
comment markers:

```bash
# ci:parallel begin 2
MRBC="$mrbc" ruby scripts/bc2cpp/a_check.rb
MRBC="$mrbc" ruby scripts/bc2cpp/b_check.rb
# ci:parallel end
```

The bc2cpp gate uses four workers. The generic helper defaults to
`CI_PARALLEL_JOBS`, then three, when a marker omits the number. Each command
runs in a subshell and inherits the step's variables; assignments made inside
that subshell cannot configure later commands. Output is saved per command and
reported in input order (only for a failed command; see "Quiet output"). A
failed command keeps its status, all commands in the group are reported, and
subsequent commands do not run after a failed group.
The timing table sums command durations, which can exceed elapsed group time.

Only read-only shared build state belongs in a group. Prepare a shared mruby
library first, and keep source-mutating checks isolated. Summary writers need
separate `GITHUB_STEP_SUMMARY` files followed by ordered concatenation after
the group; otherwise parallel writers share one output file.

### Quiet output

`bc2cpp-build` prints the output of a failed command only:

- `scripts/ci/timed_checks.rb` keeps a passing check's output in a log and
  prints just its row of the timing table. A failed check is printed in full
  under `== FAILED (exit N, Ns): COMMAND`, before the table.
- `scripts/ci/quiet_run.bash COMMAND...` does the same for one long step, the
  closed-world build. On success it prints one line with the time, the number
  of output lines and the number of `: warning:` lines. On failure it prints
  the whole log in a collapsed group, then the last 200 lines
  (`QUIET_RUN_TAIL`) and the status.

Both still print the `::error`, `::warning` and `::notice` workflow lines a
passing command writes, so its annotations reach the run page. Set
`CI_VERBOSE=1` on a step (or rerun the job with it in the environment) to print
every command's output again. A serial check runs in a brace group with its
output on a duplicated descriptor, so it still runs in the step's own shell.

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

### RGSS::Tts in limited builds (ADR 0417)

`scripts/tts_limited_check.rb` (the `ruby-checks` job, no submodules needed) evaluates the real `mruby-rgss` and
`mruby-rpg2k` `mrbgem.rake` files for every build name and fails unless `tts.cxx`, `RGSS_NO_TTS` and the
`speak_message` source (`map_tts.rb` against `map_tts_off.rb`) are exactly what `tools/rgss_tts_config.rb` says, the
bc2cpp source sets (`compiled_gems.rb`) agree, and `speak_message` behaves as before where Tts exists. With `--bc2cpp`
(an explicit local invocation requiring `MRBC`) it also runs the wio closed world for `mruby-rpg2k-compiled` and fails if the
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

### Host IR facts

`scripts/bc2cpp/ir_facts_check.rb` groups the exact-class, container-shape,
numeric-class, return-site and origin-transfer host checks in one process.
Each case loads in a private namespace; their assertions and failure behavior
remain separate. The coverage runner invokes the suite once, without MRBC or
native source prerequisites.
