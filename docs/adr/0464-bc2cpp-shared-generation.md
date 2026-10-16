# 0464. bc2cpp: one analysis for the compiled gems of a build

Date: 2026-10-16

## Status

Accepted

## Context

A build compiles four gems with bc2cpp (`mruby-lcf-compiled`, `mruby-rpg2k-compiled`, `mruby-rgss-compiled`,
`mruby-core-compiled`, `tools/bc2cpp/compiled_gems.rb`). Each `mrbgem.rake` ran `bc2cpp.rb` over the same closed
world with the same environment except for five keys: `OUT_SYMBOL`, `OUT_DIR`, `ONLY_OWNERS`, `OTHER_OWNERS` and
`OTHER_DECLS_HEADER`. Of those, only `ONLY_OWNERS`/`OTHER_OWNERS` steer anything, and only from `compile_all` on.
Everything before that point is the whole-program analysis: mrbc, the registry, the closed world, the scans, the
layouts, and the fixed points `CodeGen.new` runs (70% of a pass by StackProf, ADR 0461). That analysis was done four
times per build. `never_called_registrations`, `static_dispatch_registrations` and `core_mrblib_check` repeat the
pattern, one run per gem.

A cache of the analysis would have to serialise the generator's object graph, procs and default-proc hashes
included, and key it by everything it read. A stale entry would produce wrong code. Forking needs neither.

## Decision

* `bc2cpp.rb --units PLAN srcs...` (`tools/bc2cpp/shared_generation.rb`; a command-line flag, not an environment
  switch). PLAN lists units, each with its values of `SharedGeneration::UNIT_KEYS` and its stdout and stderr files.
  The process runs the analysis once. At the point where `ONLY_OWNERS` is first read, it forks one child per unit.
  Each child sets its unit's keys, points stdout at the unit's file, starts its stderr with everything the analysis
  printed (mrbc's output included), copies the scratch `.mrb` a separate run would leave in its `OUT_DIR`, and
  continues the main block. It therefore emits exactly what a separate run with that environment emits. The parent
  waits, appends each unit's stderr to its own, and exits with the first failure (`exit!`, so the report writers run
  once, in the children, as in separate runs). Nothing is stored between processes, so nothing can go stale.
* **The premise is enforced.** Between the two reads at the top (`OUT_SYMBOL` and `OUT_DIR`, which only name the
  scratch `.mrb`) and the fork, any `ENV` read of a unit key, or of the whole environment, raises
  `SharedGeneration::Error` and fails every unit. A plan whose units differ in any other key is refused.
* **The build.** `bc2cpp_compiled_gem_job(spec, root)` (compiled_gems.rb) holds each gem's environment, sources and
  output, which used to be four copies in the `mrbgem.rake` files. `Bc2cppCompiledGemGeneration.generate(spec,
  root)`, called by each gem's `file` rule, generates under one mutex that gem's file and every other compiled gem of
  the same build whose file task is `needed?`. The gems are grouped by their environment without the unit keys plus
  their sources; one group is one process. Under `rake -m` the first rule to run generates the group, and the others
  find their file done. A group of one is the old single command.
* `NeverCalledRegistrations.run_bc2cpp_full_many(gems, ...)` is the Ruby-level form (through
  `SharedGeneration.run`). `run_bc2cpp_full` is its one-gem case, and `static_dispatch_registrations` runs its three
  gems through it.

## Consequences

* A build does the whole-program analysis once instead of four times. The four compiles then run as four parallel
  children, which share the analysis's memory copy-on-write. Earlier local measurement: the four separate wio
  closed-world runs took 523 s of wall time in parallel on a shared 4-core box (load average 7). The benchmark of
  record is this PR's CI `bc2cpp-build` duration against master's.
* `scripts/bc2cpp/shared_generation_check.rb` (in `bc2cpp-build`) checks a two-unit plan against two separate runs
  (stdout, stderr and decls headers byte for byte), the plan refusals, the ENV guard, and the build helper's
  grouping key.
* An error before the fork is reported once, through the parent's stderr; an error after it is reported by the unit
  that hit it.
* A future read of a unit key earlier in `bc2cpp.rb` fails every shared run loudly instead of sharing a wrong analysis.
  Such a read must either move after the fork or the key must leave `UNIT_KEYS`.
