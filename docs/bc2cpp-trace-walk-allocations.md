# Receiver-trace walk allocations

`trace_new_target_walk` (the backward receiver-class walk behind
`trace_new_target`) runs once per receiver question and recurses through
`.dup`, chained accessors and index reads. Each call used to build a fresh
constant-path Array, a RESCUE barrier lambda and an entry lambda; the two
closures also moved the method's locals to a heap environment, and the call
through `Irep#walk_writers` built a keyword Hash. `IvarLayout.trace_type_walk`
and `IrepScans#walk_dominating_writers` had the same entry-closure shape.

## What changed

- **Entry handling without a closure.** `IrepScans::REACH_ENTRY` is an
  `exhausted:` callback that closes over nothing and returns a frozen
  `IrepScans::EntryReached` per register (memoized). No walk block ever
  returns one, so a caller recognizes "the top of the body was reached with
  this register" and then applies its own entry rule with its current locals
  (`use`/`read`, `dominated`, `mand`, `arg_classes`, ...). The entry rule and
  the point at which it reads those locals are unchanged.
- **Hoisted barriers.** The RESCUE-write barriers are constants
  (`TRACE_RESCUE_WRITE`, `TRACE_TYPE_RESCUE_WRITE`); the identity
  `exhausted:` callback is `IrepScans::LAST_REG`.
- **Shared empty path.** The constant path starts as a frozen empty Array and
  is replaced by a fresh Array only when the first `GETMCNST` segment (or the
  final `GETCONST` prefix) is prepended.
- **Direct walk.** The two hot walks call `BytecodeIR::Program#walk_writers`
  directly, skipping the keyword-splat Hash of the `Irep` forwarder.
- **Nil owner names.** `resolve_owner_name` is skipped when the traced class is
  nil (it returns nil for nil), which saves the context Hash.
- **Other `Kernel#lambda` sites** in the same profile: `named_layout` memoizes
  one layout lambda per method name, `inheriting_subclasses` uses a
  `class_has_mixins?` method, `guarded_game_integer_range` keeps one barrier
  per irep (it still reads `fixnum_proof_ctx` when called, so
  `FixnumBarrierShadow` sees its swapped context), `guarded_fallback_line`
  calls `ClosedWorld#refusal` directly, and the `method_return_class:` callable
  is built once per `CodeGen` (`dispatch_return_class`).

Recursion, result order and memo/query isolation are unchanged: the walks still
recurse on strictly smaller indices, `TraceReaching::IN_PROGRESS` keys are
unchanged, and no shared object is mutable (the path Array is copied before the
first mutation; the memoized lambdas and `EntryReached` values hold no
per-query state).

## Evidence

Sealed Optcarrot compile (`scripts/bc2cpp/compiler_profile.rb --optcarrot`),
Ruby 4.0.5 +YJIT, one warm-up run and then three alternating unsampled runs
(`--mode none`):

| Run | Base `allocated_objects` | Base `elapsed_seconds` | New `allocated_objects` | New `elapsed_seconds` |
| --- | ---: | ---: | ---: | ---: |
| 1 | 15,287,787 | 7.939 | 14,949,156 | 7.818 |
| 2 | 15,287,870 | 7.747 | 14,949,077 | 7.839 |
| 3 | 15,287,810 | 7.757 | 14,949,131 | 7.782 |

About 338,700 fewer allocated objects per compile (2.2%). Elapsed time moved
within run-to-run noise, so no speed claim is made.

In the object-mode stackprof, `Kernel#lambda` plus `RubyVM::FrozenCore.lambda`
fell from 3,437 to 738 samples (of about 155k), and `trace_new_target_walk`'s
own samples from 1,279 to 593.

The generated C++ is identical apart from the per-run temporary-world path
(`bc2cpp-compiler-profile-...`, including its hex-encoded string-pool copies).
The profiling procedure is in [compiler data profiling](bc2cpp-compiler-data-profile.md).
