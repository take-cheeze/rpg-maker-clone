# bc2cpp CI duration profile (2026-10-12)

Where the wall-clock time of the bc2cpp CI goes, what changed to shorten it, and what is left. CI numbers come
from the Actions API (job `started_at` to `completed_at`, queueing excluded). Local numbers come from a 4-core
Ubuntu 24.04 sandbox with the same toolchain as the runner, no sccache; the local serial run of `bc2cpp-width
(int32-a)` took 45.8 minutes against 45.4 on CI, so the local harness is a fair stand-in for the checks.

## 1. Where the time was

Nightly workflow (`bc2cpp-nightly.yml`, split from `build.yml` in #2133). Its first run has not happened yet, so
the table is the last master run before the split, `38189898041` (commit `fb2d284`, 2026-10-12), which ran the same
shards in `build.yml`. Job wall times in minutes:

| Job | Wall | Notes |
| --- | ---: | --- |
| `bc2cpp-width (int32-a)` | 49.2 | checks step 45.4; 14 commands, run one after another |
| `bc2cpp-checks (call-facts)` | 45.3 | cancelled at its 45 minute `timeout-minutes` (checks step 43.2) |
| `bc2cpp-width (int32-b)` | 30.0 | checks step 26.7 |
| `bc2cpp-checks (coverage)` | 24.3 | 3 commands |
| `bc2cpp-checks (core-flow-mutants)` | 22.4 | 3 commands |
| `bc2cpp-checks (core-mrbtest)` | 21.5 | failed; checks step 19.5, 38 commands |
| `bc2cpp-checks (native-class-arms)` | 21.4 | 4 commands |
| `bc2cpp-checks (hot-proven-miss)` | 21.0 | 1 command |
| `bc2cpp-checks (hot-only)` | 20.0 | 1 command |
| `bc2cpp-checks (class-narrowing)` | 19.1 | 2 commands |
| `bc2cpp-build` (the PR gate) | 10.3 | 8.0 of it is one `rake` run building the bc2cpp mruby core |

Setup (checkout, Nix store restore, sccache, `cmake` configure, the host `mrbc`) is 1 to 3 minutes of every
shard. The checks step is the rest, so the shards' length is the sum of their commands. Shards with a timeout
(`bc2cpp-checks`, `bc2cpp-width`) were the risk: `call-facts` hit its 45 minute limit.

Per-check time of `int32-a` on CI (seconds, sequential), the 15 commands:

| Check (32-bit leg) | s |
| --- | ---: |
| `numeric_slow_check.rb` | 636 |
| `class_narrowing_check.rb` | 456 |
| `call_results_check.rb` | 453 |
| `call_facts_check.rb` | 269 |
| `computed_send_check.rb` | 248 |
| `constructor_pools_check.rb` | 190 |
| `step_inline_check.rb` | 110 |
| `native_ivar_scopes_check.rb` | 102 |
| others (lcf_row_flow, tuple_return, numeric_native_direct, getidx, fixnum_overflow, index_closed) | 258 |
| total | 2723 |

## 2. What the generator costs

Every `Bc2cppFixtureRuntime.generate` call runs `tools/bc2cpp/bc2cpp.rb` as a new process, closed world
(`BC2CPP_CLOSED_WORLD=1`, `NATIVE_SRCS` = the mruby and gem C sources). `numeric_slow` makes 79 such calls,
which take 620 s of its 637 s. A call costs about 7.9 s (7.2 s for a one-method fixture).

Phase timings of one closed-world call (`BC2CPP_PROFILE_TIMINGS=1`):

| Phase | s |
| --- | ---: |
| closed world + native scans | 2.09 |
| class layout fixed-point passes | 1.90 |
| C++ emission + symbol rewrite | 1.53 |
| compile all methods | 0.56 |
| return/fixnum proofs + final ivars | 0.54 |
| every other phase | 0.3 (plus about 0.3 s of process start-up) |

A sampling profile (a `Thread` sampling the main thread's innermost `tools/bc2cpp` frame, loaded with `RUBYOPT`,
so the generator child processes are included) puts about 70% of the samples in reading and scanning the native
sources: `native_expression_devirt.rb` (`file?`, `stat`, `scan`) and `source_text.rb` (`read`, `binread`).
Those files are the same on every call of a check.

Sampled by the first-level call under the generator's main script, the largest items are `emit_numeric_slow_helpers`
(15%, all of it the first `CallFacts#definers` question, which builds the world lazily), `analyze_exact_class_expressions`
(12%), `outside_world_tokens` (14%), `ClosedWorld#scan_native` (7%) and `analyze_native` (6%). Memoizing
`SourceText.read` in the process was tried and gave no change (8.0 s against 7.2 s, byte-identical output): the files
are in the page cache and the cost is the scanning, so only caching scan results across processes would help.

A StackProf run (wall mode, 1 ms, through `RUBYOPT=-r` so the generator child is profiled) is more exact than the sampler
above: of 8070 samples `String#scan` was 42% self time and `CoreMixins.definers_in` 22%, GC 8%. `definers_in` built
three regexes by interpolating the method name inside its per-line loop, for every line of every core Ruby source and
every name; building them once and returning early when the source does not contain the name is exact (the generated C++
is byte-identical) and took a one-method call from 7.8 s to 5.5 s and the calls inside `numeric_slow` from 7.9 s to
6.5 s (the check from about 630 s to 576 s). After that fix `String#scan` is 61% self time: the regexes over the native
sources, which only a cache of their results across processes would remove.

Three more exact changes remove most of the repeated scanning (the generated C++ is byte-identical):

* `NativeExpressionDevirt.class_variable_map` ran twice for every native source (once from each ROM scan); it is now
  computed once per source string.
* The `(\w+)\s*=\s*...` patterns in it, and in `native_class_module_names`, gain a `(?<!\w)` guard. A match cannot
  start in the middle of a word, because the match that starts at the word's first character is found first and
  has the same tail, so the guard only skips starts that never win (Onigmo otherwise retries every position of
  every word). The patterns give identical matches over all 82 native sources.
* `rom_entries` returns early when the source has no `MRB_MT_ENTRY`, and the `boot_defclass` scan only runs for
  a source that contains the word.

Together with the `definers_in` change, a one-method closed-world call goes from 7.8 s to 3.45 s (-56%) and
`numeric_slow` from about 630 s to 398 s (same 329 passing checks).

Checked for identity on the whole engine: the first generator pass of `coverage_report.rb` (all compiled gems, the
closed world the build uses) produced the same 21,620,134 bytes (445,323 lines) of C++ and the same diagnostics with the
committed tool and with this change. That pass is not faster (528 s against 514 s): its time is in compiling the methods,
so these changes help the fixture-based checks, which pay the closed-world setup on every call, not the engine build.

Ruby version: with the fixes in, Ruby 4.0.7 built here with YJIT takes 3.2 s for the same call against 3.45 s on
3.3.6 (-6%). Running it with `--yjit` is slower (3.6 to 3.9 s): the process lives about three seconds, which
does not repay JIT warm-up. Before the scan fixes the gap was the same size (5.3 s against 5.6 s), so a newer Ruby is
a small, separate gain, not a substitute for the fixes.

Whole-output caching does not help: none of the 79 calls in `numeric_slow` repeats an earlier one (the digest is
argv, the `BC2CPP_`/`NIS_` environment and the fixture text). What repeats is the native-source world.

## 3. What changed

`scripts/ci/timed_checks.rb` already ran independent commands in a `ci:parallel` group (#2130). This change puts
the long shards' independent single-process commands in groups of three:

* `bc2cpp-width` `int32-a` and `int32-b`: every check after the `BC2CPP_MRUBY_FULL32` export.
* `bc2cpp-checks` `call-facts`, split into three runners: `call-facts` (the 14 non-mutation commands: the first
  builds `BC2CPP_FULL_BUILD_DIR` and runs alone, the other 13 read it as a group), `call-facts-mutants-a` and
  `call-facts-mutants-b` (the ten mutation checks, 1013 s and 806 s of serial time, run in sequence because each
  already runs a four-wide mutant pool). `call_facts_mutation_check` is the one `.mutants/` user.

The rules that make this safe are in `docs/ci.md` ("Parallel groups"): one builder per directory, read-only use of a
built directory, and no two `.mutants/` users at once. The scripts were not changed.

Measured here (4-core sandbox, `int32-a`):

| Run | Wall | Passing checks | Failing |
| --- | ---: | ---: | ---: |
| serial (`timed_checks.rb`, as before) | 45.8 min | 1329 | 0 |
| three at a time | 18.1 min | 1329 | 0 |

The two runs shared the box with each other and with other profiling runs (the load average reached 8 on
4 cores), so both wall times are approximate. The serial run's 45.8 minutes match CI's 45.4 for the same
shard, which suggests the sharing did not inflate it much. The result sets are identical (the same 1329
`ok` lines, no failure in either).

`call-facts` as one serial shard took 3807 s (63.5 min) alone on the box, with 1189 passing checks, against
CI's 45 minute timeout; it could not have passed there. With all 23 later commands in one group it took 2022 s
(33.7 min, same 1189 checks, partly sharing the box with the `int32-a` baseline). The mutation checks are 1819 s
of that serial time and the non-mutation commands 1988 s, so the shard was split across runners as above.
After the split, the new `call-facts` shard (14 non-mutation commands, one builder then a group of three) took 1114 s
(18.6 min) alone on the box with 1076 passing checks and no failure. The two mutant shards were not timed on their
own; their serial command times are 1013 s and 806 s, plus one full-core build in the first. Their ten checks plus
those 1076 make the same 1189 as the serial run.

## 4. Next levers

Ranked by what they would save on the critical path. The first item is partly done (ADR 0405); the rest are not.

1. **More of the native-source scans in the disk cache (ADR 0405).** The cache is in for the three pure scans
   (`numeric_slow` 398 s to 316 s). `ClosedWorld#scan_native`, `CallFacts::Answers#native_scan` and `NativeDirect.*`
   are about 20% of a call more but fill instance state while they scan; making them return a value first would let
   them use it. A warm generator process (or batching fixtures into one) would remove the repeated work altogether,
   at the price of resetting the generator's global state between calls.
2. **`coverage` (3 commands, 22.5 min).** The two bash reports append to `$GITHUB_STEP_SUMMARY` with `tee -a`, so
   they cannot share a group without interleaving the summary. Giving each its own summary file would allow it.
3. **Single-command shards** (`hot-only`, `hot-proven-miss`, `block-arm-reach`, `core-exact-direct`,
   `core-mutants`). Each waits on one script, so only parallelism inside that script (its own mutant or
   fixture loop) would shorten them.
4. **`bc2cpp-build`** (PR gate, 10.3 min). The 8 minutes are one `rake -m -j4` of the core, so only the sccache hit
   rate on pull requests or the compile flags would move it. Not changed here.

## 5. Method notes

* Ruby version: the generator needs Prism, so 3.1 and 3.2 cannot run it (they fail at load). 4.0.7 was built with
  `RUBY_CONFIGURE_OPTS=--enable-yjit` for the comparison above.
* The mruby submodule must have its patch chain applied for every measurement (`cmake --build <dir> --target
  mruby_host_mrbc` does it). Restoring `3rd/mruby` to clean, as a clean `git status` needs, unapplies it; checks such as
  `index_closed` and `integer_constants` then fail, and generator timings change.
* Local setup for these runs: `libsdl2-dev`, `libsdl2-mixer-dev` and `gperf` from apt, `gem install rake`, and
  `LANG=C.UTF-8`. Without the UTF-8 locale `fixture_runtime.rb` fails with `invalid byte sequence in US-ASCII`.
* The per-shard checks were run through `scripts/ci/timed_checks.rb` exactly as the workflow's step does.
* The `numeric_slow` profile run had 11 C++ compile checks fail, from a `PATH` in the wrapper that had lost
  `/usr/bin`. That changes which checks passed, not the 79 generator calls or their timings.
* Wrapping the generator (to time it or count its calls) needs care: `numeric_native_direct_check.rb` and the
  other checks that read `BC2CPP_TOOL` use its directory as the tools directory, and `bc2cpp.rb` runs its main
  program only when `$PROGRAM_NAME == __FILE__`. A wrapper must live in `tools/bc2cpp/`, and it must set
  `$PROGRAM_NAME` before it `load`s the real file.
