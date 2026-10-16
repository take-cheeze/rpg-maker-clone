# 0465. bc2cpp: fail fast, and no fixed point runs unbounded or ends partial

Date: 2026-10-16

## Status

Accepted

## Context

A declaration error should stop a build as soon as its inputs allow, not after the expensive fixed points. And a
slow or non-monotone proof must neither stall a build nor hand on facts that were still changing.

The phases of a generator run, in order, with what can abort in each (`BC2CPP_PROFILE_TIMINGS` names, times from the
wio shipped pass):

| # | Phase | Ends at | What aborts there |
| --- | --- | ---: | --- |
| 1 | mrbc + parse + registry | 2.7 s | mrbc errors |
| 2 | closed world + native scans | 5 s | `BC2CPP_CLOSED_WORLD` refusal, the lint cross-check (ADR 0368) |
| 3 | global facts + annotations | 8 s | `RBS_SIGNATURES` (unusable signatures); on the tracking branch also `RBS_CHECKED_PARAMS` (ADR 0456) and `DeclaredConstants` (ADR 0455); `RBS_RECORD_TYPES` |
| 4 | layouts (ivar, class, element) | 14 s | `Fixpoint::NotConverged` (this ADR) |
| 5 | return/fixnum proofs, final `CodeGen.new` (the fixed points) | 25 s to most of the pass | `Fixpoint::NotConverged`; then `DECLARED_RETURN_CHECK` (tracking, ADR 0455) and `RBS_SEED_CONTRADICTION` |
| 6 | compile all methods | | `NOMETHOD_REVIEWED`, `STRICT_HINTS`, `PROVEN_MISS`, the review scope |

Every check that can abort already runs at the first point where its inputs are final, and the build aborts in the
first failing phase. The signature, checked-parameter, declared-constant and record-type checks run in phase 3,
before any expensive fixed point. On the tracking branch, the known `RBS_CHECKED_PARAMS` errors (82 unproven
parameter types) stop the wio shipped pass after 7.6 s and the rpg2k hot-only probe after 8.4 s, with no layout or
`CodeGen.new` work done. The checks that wait on a late fixed point stay where they are:

* `DECLARED_RETURN_CHECK` needs the final generator's return-class and numeric fixed points (`CodeGen.new`).
* `RBS_SEED_CONTRADICTION` needs `FIXNUM_RETURN_PROOF` of the final generator and `ClassArgTypes` over the final
  class layout.
* `NOMETHOD_REVIEWED`, `STRICT_HINTS`, `PROVEN_MISS` and the review scope judge the compiled methods.

Within one phase every error of that phase is still reported together. The type check (`BC2CPP_TYPE_FACTS`) still
collects across phases and exits nonzero when any is an error.

The fixed points were not all bounded:

* The four layout sweeps (`ClassLayout`, `IvarLayout`, `ArrayElementLayout`, `HashElementLayout`) ran `10.times` and
  stopped there whether or not the table had settled, silently keeping a table that was still changing.
* The two pooled growth loops in `CodeGen.new` (the return classes with the class pools and checked alias names; the
  numeric entry-argument, ivar-group, return, tuple and constant pools) were `loop do` with no limit. They terminate
  because every mask only grows by union or is dropped for good, but nothing bounded how long that took.

## Decision

`tools/bc2cpp/fixpoint.rb`: `Fixpoint.iterate(analysis, limit) { changed }` runs rounds until one changes nothing.
If the limit is reached while rounds still change, it raises `Fixpoint::NotConverged`, naming the analysis, the limit
and the loop's file and line, and none of the facts are used. The limits are constants, with no environment switch:

* `SWEEP_LIMIT = 32` for the four layout sweeps. A sweep that settles within 10 rounds, the old cap, gives exactly the
  old table. One that needed more now either settles (a fully converged table where a partial one was used before)
  or stops the build.
* `GROWTH_LIMIT = 200` for the two growth loops in `CodeGen.new`.

The loops that cannot run long need no limit, because each round removes an element from a finite set or adds one to
it: the drop loops of `FIXNUM_RETURN_PROOF`, `ARRAY_RETURN_PROOF`, the entry-argument Fixnum proof and
`IntegerConstants`; the growth of the `IntegerConstantRanges` known set and of the resumable set; and the
`seen`-guarded superclass walks. The per-method dataflows were already capped (`DATAFLOW_MAX_STATES`,
`FIXNUM_PROOF_REACHING_MAX_STATES`, `ir_context_results` and `ir_call_graph_types` `MAX_ROUNDS`).

## Consequences

* A non-monotone analysis, or a program that outgrows a limit, stops the build with a located error instead of
  looping or shipping half-settled facts.
* Raising a limit is a code change that is reviewed like any other.
* `scripts/bc2cpp/fixpoint_check.rb` (in `ruby-checks`, seconds) checks convergence, the error and its location,
  that the limits are constants, and that the six loops run under `Fixpoint.iterate`.
* The benchmark of record is this PR's CI `bc2cpp-build` run: when every sweep settles within 10 rounds, the
  generated code and its duration are unchanged.
