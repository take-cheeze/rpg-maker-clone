# 0461. bc2cpp: reuse two whole-program answers within one run

Date: 2026-10-16

## Status

Accepted

## Context

A whole-program generator pass over the engine (the wio closed-world shipped pass, `ship2.rb`) took 236 s on a
shared 4-core box. Every compiled gem of a build, `never_called_registrations`, the type check and the hot-only probes
run that same analysis, so its cost is paid many times in one CI job. A StackProf profile (CPU mode, 5 ms) of the pass:

| Where | Share |
| --- | ---: |
| `CodeGen.new` of the final generator (the numeric, return-class and class-pool fixed points, `drop_unsafe_embeddings`) | 70% |
| of which `NumericFlow.states` (inclusive, recursive) | 67% of the pass |
| of which `return_class_context_def_mask` (called only from `return_class_scoped_send_mask` on a cache miss) | 42% |
| `foreign_method_names`, called by `ClosedWorld#outside_ruby_paths_defining` | 10% (after the fix below, 17% of the remaining `String#scan`) |
| `CodeGen#compile_all` | 8% |
| GC | 12% |
| everything before `CodeGen.new` (mrbc, registry, closed world, scans, layouts, the fixnum-return probe) | 10% (23 s) |

Two of these are the same question asked again and answered again from scratch:

1. `return_class_scoped_send_mask` memoized a positive answer and a `nil` for an unusable class, but returned before
   caching when the receiver-specific flow gave no class (`mask` unusable). Every later send with the same receiver
   class, name and argument classes re-ran the whole context-sensitive dataflow of the callee body.
   That answer was not cached because the dataflow cuts recursion: a query already on the stack answers `nil`, and an
   answer computed under such a cut depends on the order in which questions were asked.
2. `ClosedWorld#outside_ruby_paths_defining(name)` called `foreign_method_names([path])` for every outside Ruby file
   and every asked name: each file was read and its regexes run once per name (ADR 0416 removed only the re-parse).

## Decision

* `SCOPED_NEGATIVE_MEMO`: the scoped return-class tables count every cut (`@rc_scoped_cuts`: a query already active,
  a callee body already being analysed, a scoped flow already on the stack). A negative answer is cached only when the
  count did not change while it was computed. Then the answer read nothing order-dependent: every sub-answer it used
  was itself either cached or computed without a cut, so asking again gives the same `nil`. Answers computed under a
  cut stay uncached, exactly as before.
* `ClosedWorld#outside_ruby_path_method_names(path)` keeps one name set per outside Ruby file for the run.

## Consequences

* The pass takes 135 s with the first change and 112 s with both, against 236 s (each under the same profiler, on
  the same box). The generated C++ is byte-identical to the unchanged tool's with both changes. The diagnostics are
  identical except for the absolute checkout paths in `SIG_FILE` lines.
* A foreign Ruby file that does not parse is now reported once per run, not once per asked name.
* What remains is the analysis itself: `NumericFlow.states` is still 42% of the pass, `drop_unsafe_embeddings`'s
  probing compiles 19%, GC 15%. The other reuse levers (the scan cache, one analysis shared by the compiled gems) are
  separate changes.
