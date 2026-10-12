# 0416. bc2cpp: a warm generator that forks one generation per request, opt-in

Date: 2026-10-12

## Status

Proposed

## Context

ADR 0415 rejected a warm generator process as larger and riskier than a disk memo of the scans, and left it open.
Every fixture check still starts one `bc2cpp.rb` process per generation (`Bc2cppFixtureRuntime.generate`). A
one-method call costs about 3.5 s to 4 s here, of which about 0.3 s is loading the tool's ~270 Ruby files and
about 1.4 s to 1.9 s is the outside-world scans that ScanCache memoizes (ADR 0415). The rest is generation.

A warm process removes the repeated load and scans, but it is only sound if no state from one generation reaches
the next. The generator keeps state in `CodeGen` class-level instance variables, module constants and class-level
memos (listed below), and several of them are filled per run. So the design has to keep that state out of the
parent, not just reset it.

## Decision

A prototype behind `BC2CPP_WARM_GENERATOR=1`, off by default:

* **A server process** (`tools/bc2cpp/warm_generator.rb --serve`, started by the check process through
  `Open3.popen2`) requires `bc2cpp.rb` once and warms the three scans of ADR 0415 into an in-process memo
  (`ScanCache.memory`, nil by default). It then answers JSON lines: `boot`, `generate`, `digest`. It never runs a
  generation itself.
* **Each `generate` request forks a child.** The child reopens stdout and stderr onto files, replaces its ENV with
  the request's full environment, sets ARGV, and `load`s `bc2cpp.rb`, so the main block runs. It leaves with `exit`,
  so the tool's `at_exit` report writers run once, as they do in a subprocess. `generate_in_child` raises if it is
  called in the server's own process, which is what keeps the server's state clean.
* **Load-time gates.** The server records every ENV key the tool reads while it is required (`EnvTrace`, prepended
  into ENV in the server only). A request whose value for one of them differs from the server's runs as a
  subprocess, through the same `Open3.capture3` call as before, and is counted. Today these are 15 `BC2CPP_*`
  report switches read by `require`, `MRBC` (a constant in `irep.rb`), and the keys RubyGems and prism read.
* **Exit and errors match a subprocess.** The server leaves with `exit!` after flushing, so its boot-registered
  `at_exit` writers do not overwrite the children's reports with its empty state. An uncaught error in a child is
  printed with the server's own frames removed and the tool's top level reading `<main>`, so the text is the one a
  subprocess prints.
* `scripts/bc2cpp/fixture_runtime.rb` routes its one `Open3.capture3` through `generator_run`; the default path is
  that same call. `scripts/bc2cpp/warm_generator_check.rb` checks the opt-in and is not run by CI.

### What the fork relies on being clean

`scripts/bc2cpp/warm_generator_check.rb` and an in-process audit (snapshot of every tool-owned class and module
before and after one generation) give the list below. Names are the class-level instance variables of `CodeGen`
and the constants of the tool's modules that one generation changes; "copied correctly" means the fork's copy
of the server's state gives the same bytes as a fresh process.

| Group | State (one generation sets it) | Fork outcome |
| --- | --- | --- |
| Assigned unconditionally in the main block before any read | `CodeGen.module_names`, `core_aliases`, `core_result_opaque_defs`, `core_result_installed_names`, `core_hidden_defs`, `core_guarded`, `core_methods`, `core_compare`, `stable_class_constants`, `computed_send_tables`, `struct_members`, `integer_constant_values`, `integer_constant_ranges`, plus `UniqueClassNames`/`ConstructClassNames` tables, `RecordHash` pool and tables, `EscapeAnalysis.world` | Copied, then overwritten by the child. Safe because the server never sets them. |
| Assigned only under an environment switch | `CodeGen.build_gem_names` (`BC2CPP_CLOSED_WORLD=1`), `native_source_paths` (`NATIVE_SRCS`), `wired_embeddings` (unless `BC2CPP_SELF_REGISTERING=1`), `hot_only_excluded` (`BC2CPP_HOT_METHODS`) | **Would leak.** A generation that set one of them, followed by one that does not, sees the stale value. The server never sets them, so a fork sees nil, as a fresh process does. |
| Accumulators | `CodeGen::NATIVE_OWNER_MAP_TALLY` (`Hash.new(0)`, written by an at_exit hook to `BC2CPP_NATIVE_OWNER_MAP_REPORT`) | **Would leak.** Counts add up across runs in one process, so the second run's report includes the first's. |
| Memos keyed by content, file identity or object identity | `NativeExpressionDevirt::SOURCE_CACHE` (path, mtime, size), `REGISTRATION_CACHE` (file identity), `ASCII_VIEWS` and `CLASS_VARIABLE_MAPS` (`compare_by_identity`), `NATIVE_OWNER_MAP_CACHE` (path list), `YIELD_REACH_MEMO` (identity of `ireps`), `InsnDecoder::OPERAND_SIZES` (format, ext), `ScanCache` digests | Copying is correct: each entry is a function of its key. The three ADR 0415 scans are warmed on purpose. |
| Memos keyed by path or directory only | `NativeDirect` `@registrations[path]` and `@sibling_owners[dir]` | **Would leak** if a parent ran a generation and a file or directory at the same path changed afterwards. Not reached by a fork, because the server never runs a generation. |

Two rules follow from the table, and both are enforced in code rather than by review:

1. **The server never runs a generation.** `generate_in_child` raises in the server's pid; the main block is
   reachable only through a fork. The server warms scans, which fill only the content-keyed memos above.
2. **The memo warms only the three ScanCache scans, with the source lists a closed-world run passes.** A scan
   that prints anything is not memoized: the memo is turned off and the text is printed once. A request with other
   source lists misses the memo (the key covers the list) and computes.

The `digest` request returns a digest of the tool's class-level state and constants. The check compares it before
and after forked generations; it is process-local (`Object#hash`).

### Evidence

Setup. Measured on origin/master 38d521e; the branch was rebased onto 59cc590d afterwards, and the generator
changes in between do not touch this path. The workload is 8 one-method generations and the first 13 generator calls of `numeric_slow_check.rb`,
recorded with argv, environment and the output directory (`BC2CPP_TOOL` pointed at a recorder). The check stops
at its 14th call in this sandbox: its own assertions depend on the patched mruby tree, which the worktree lacks.
Each recorded call was replayed with the full closed-world source lists of the main checkout's `3rd/mruby`
(the worktree's submodule is empty; the 16 source files it would scan alone would understate the scans). Both
modes get the same argv, the same environment and a fresh copy of the same directory. Three interleaved
repetitions, with the order alternating per pair. The machine has 4 cores and was shared: the load average was
10 to 16 for the whole run, so the absolute times are inflated; the A/B ratio is the measurement.

| Workload | Runs | One subprocess per run (A) | Warm fork per run (B) | Gain |
| --- | ---: | ---: | ---: | ---: |
| one-method fixtures | 24 | 4.36 s mean | 2.00 s mean | 54% |
| `numeric_slow` calls 1 to 13 | 39 | 5.81 s mean | 3.28 s mean | 44% |
| all | 63 | 331 s total | 176 s total | 47% |

The server's boot (`require` plus the warm scans) took 2.8 s, once per check process.

Identity. For all 63 pairs the C++ on stdout, the stderr text and every file the tool wrote (the decls
header) are byte-identical between A and B; 63 of 63 requests were served by fork, none by subprocess.
`scripts/bc2cpp/warm_generator_check.rb` adds the failure path (a fixture that does not compile gives the same
message), the at_exit report (`BC2CPP_NATIVE_OWNER_MAP_REPORT`, byte-identical; it fails if the child uses
`exit!`, which was checked by mutation), the gated subprocess fallback, and an unchanged server digest.

Default path. The same 21 recorded calls, run as subprocesses with this branch's tool and with origin/master's
`tools/bc2cpp` (the same repository root, linked), give identical stdout, stderr and files in 21 of 21 cases (origin/master's tool was placed in a tree that
links every other entry of this worktree, so only `tools/bc2cpp` differs).
`scripts/bc2cpp/scan_cache_check.rb` passes; its real-scanner section skips here because this worktree has no
`3rd/mruby`.

Leaks. Running the 21 calls in one process, in order, with the tool loaded once and each main block run in turn
(what a parent that ran generations before forking would do), every run matches a fresh process byte for byte,
and so do two probes run after them: an open-world call (no closed-world, natives or foreign sources) and a call
with `BC2CPP_SELF_REGISTERING` unset. So the state in the table does not change these outputs. It does change a
diagnostic file: one process that ran four `numeric_slow` calls wrote four `BC2CPP_NATIVE_OWNER_MAP_REPORT`
entries (`ineligible_candidate 3`, `no_ruby_definition 1`), while a fresh process for the last call alone wrote
none. The conditionally set attributes were not exercised in the reverse order (a closed-world run, then one
without the switch that sets it), so their effect is argued from the code, not measured. The fork design does not
rely on the measurement: the server runs no generation, so no child starts from a used state.

Pre-existing failure: `scripts/bc2cpp/nested_compile_state_check.rb` fails one assertion (three `CodeGen` ivars are not
classified). It fails the same way against origin/master's tool, so it is not caused by this change.

### Nightly `fast` shard (2026-10-12)

The `fast` shard has 109 commands. Thirty use `Bc2cppFixtureRuntime`, and with the flag off those checks made 204 of
the shard's 679 `bc2cpp.rb` runs (the rest are mutant pools and direct tool runs, which the flag does not change).
Replays of the shard's commands ran on this sandbox, with `LANG=C.UTF-8` (the step's locale), the same environment,
the scan cache on in both modes, and two modes started together so both saw the same load (load average 4 to 10 on
4 cores, shared with other agents).

* Flag on for every command: exit status equal for all 109; stdout and stderr differed for three checks that run a
  mutant copy of the tool (`tuple_return_mutation_check`, `integer_tag_else_check`, `block_direct_mutation_check`).
  The server loads the copy itself, so it adds a constant warning and prints a load error from its own frames.
  Those three are opted out (`BC2CPP_WARM_GENERATOR=0`) in the change below.
* Final configuration (flag on except those three) against the flag-off run: exit status equal for all 109, 102 pass
  and 7 fail in both (the same seven: sandbox failures such as `nested_compile_state_check`, which fails on master
  too). stdout and stderr identical after normalizing the per-run temp directory names, except the random `--seed` and
  timing lines of two Minitest checks, which differ between any two runs.
* Wall time: the final configuration against the flag-off run, run together: shard 1676 s against 1675 s; the
  fixture-runtime commands 370 s against 369 s (-0.5%). The first pair (flag on for everything) gave 1611 s against
  1679 s, and 394 s against 437 s for the fixture commands (+9.8%). The gain does not reproduce on this box, so it is
  not claimed. A likely cause: the nightly already keeps the ADR 0415 disk scan cache, which absorbs most of the scan
  cost the memo saves, and each fixture check pays one server boot (2.8 s above).

Leak analysis (ADR table, plus what the replay found):

* Reversed-order switches. `CodeGen.build_gem_names`, `native_source_paths`, `hot_only_excluded` and
  `wired_embeddings` are set only in the main block of `bc2cpp.rb` (lines 156 to 1758, `if $PROGRAM_NAME == __FILE__`),
  so only a generation process can set them. No process runs two generations in either mode: flag off, each run is a
  new `Open3.capture3` process; flag on, each run is a fork of a server that runs none. A check that runs closed-world
  and then open-world generations (`numeric_slow_check.rb`, for one) therefore gives each generation a fresh state.
* Not in the ADR table: `SourceText`'s once-per-process missing-path set (`tools/bc2cpp/source_text.rb`). The server's
  warm scans can add to it, and the server prints the warning once instead of per child. Not reached here: all 83
  native and 41 foreign paths the warm scans read exist in this checkout.
* Not in the ADR table: the server's stderr is not captured by the check. Warnings printed when the server requires
  the tool reach the check's stderr directly; this is the mutant-copy case above.
* Server lifetime. A normal check exit leaves no server. `kill -9` of a check leaves its server gone about 3 s later
  (EOF on the server's stdin). No cleanup step is needed.
* `scripts/bc2cpp/warm_generator_check.rb` fails one assertion in this checkout, "the report written from an at_exit
  hook is non-empty". The report is 0 bytes in subprocess mode too, so the failure does not depend on the flag.

Status stays Proposed. The identity holds on the nightly shard, but one shared box shows no reproducible speedup and
the prototype's own check fails here; the nightly run is the test that decides whether to keep it.

## Consequences

* A fixture check that opts in pays the server's boot (`require` plus the warm scans) once per check process, then
  each generation costs a fork. The default path is one subprocess per generation, as before, and its output is
  unchanged: `generator_run` is that `Open3.capture3` call, and `ScanCache` with no memo and no directory returns
  the block's value as it did.
* The prototype adds `tools/bc2cpp/warm_generator.rb`, which changes the tool digest in ADR 0415's scan-cache key
  (a cache miss, never a different output). The generator's output over the replayed checks is compared with the
  master tool's, byte for byte, in the measurements above.
* `ScanCache.memory` is in-process only. It is not Marshal'd and it never reaches disk, so the Marshal caution of
  ADR 0415 does not apply to it.
* Not done: the stateful scans (`scan_native`, `native_scan`, `NativeDirect`) are still computed per child. The
  `NativeDirect` memo keyed by path is the one that would need a content key before it could be shared.
* Nightly: the `fast` shard sets `BC2CPP_WARM_GENERATOR=1` (an `export` at the top of its checks) and sets `=0` on the
  three mutant-copy commands above. The PR gate and the other shards do not set it, and
  `scripts/bc2cpp/warm_generator_check.rb` is still not in `ruby-checks`.
* Keep or revert: the identity result holds, but the speedup is not measured on this box. If the nightly `fast` timing
  does not show a gain, revert the workflow lines; the module stays opt-in.
* Follow-up if the PR merges: decide whether to run the server per check process (as here) or one per job.
