# 0508. Dispatch-target traces answer from the IR per path, and join mode is per trace

Date: 2026-10-19

## Status

Accepted

## Context

Several dispatch-target analyses in `tools/bc2cpp/dispatch_targets.rb` and
`static_dispatch_registrations.rb` still answered by walking raw instructions
backward in index order. A backward walk takes the textually nearest writer,
which a join can skip. Four consequences were found by fixtures
(`scripts/bc2cpp/dispatch_ir_trace_check.rb`, host only):

1. `literal_container_class` (CONST_CONTAINER_SUPPORT, the SETCONST path that
   feeds `container_constants`) returned the last literal textually. For
   `X = c ? [] : {}` it answered `'Hash'`; the loop recognizers trust that
   class without a runtime check.
2. `trace_eqq_literal_receiver` (LITERAL_EQQ) took the nearest writer as the
   `when` literal. For a receiver that is `5` on one path and a call on the
   other it answered `{fixnum 5}`.
3. The reaching-definition path (`trace_new_target_reaching`) re-walked each
   definition with no dominance check. A `.new` definition walks its receiver
   on, so `(c ? A : B).new` answered `'B'`. The GETIDX alias walk
   (`arg_reg`) was linear too, so an annotated argument could be named for a
   receiver that was a literal Hash on one path.
4. The guarded mode was a process-wide depth counter (`JoinDominance.guarded`).
   A trace nested inside a guarded one (a `method_return_class` callback, a
   return proof) inherited guarded mode and its join-blind walk. The leak was
   shown by a fixture: an unguarded trace of `x = c ? [] : {}` nested in a
   guarded `SEND0` answered `"Hash"` where the reference answer is nil.

Separately, `static_dispatch_registrations.rb` (`register_kinds`,
`receiver_kinds`) hand-built basic blocks from a `starts` set and kept a
flow-insensitive writer table for each irep. The table ignored that a nested
block writes a local with SETUPVAR, so a register also written by a block
answered the kind of its local write (`:core` for a `LOADNIL`), which hides the
engine-instance methods the block may send to. Those kinds feed the load-phase
closure that decides which compiled entries are unregistered.

## Decision

* **Literal answers come from the reaching definitions.**
  `literal_container_class` and `trace_eqq_literal_receiver` take
  `BytecodeIR.reaching_definitions` at the read. Every definition must give the
  same class (or the same literal); a `.freeze` definition takes the class of
  the value it was called on, read at the freeze.
* **The container merge checks the join, not the branch.**
  `container_phi_merge` requires the jump's target to be `at + 2` and reads the
  reaching definitions at that join. The definitions before the branch miss a
  third predecessor of the join.
* **Reaching-definition sub-walks are dominance checked when unguarded.** The
  per-definition walk in `trace_new_target_reaching` and the GETIDX alias walk
  use `JoinDominance` (`walk_dominating_writers` for the alias), so a hop past a
  join ends the walk and the answer falls back to the unanimous join.
* **Join mode is an argument of each trace.** `trace_new_target` takes
  `guarded:` (default false). Its walk and reaching helpers pass it down
  explicitly, and nothing holds it in a global. A callback that starts its own
  trace asks for its own mode. `JoinDominance.guarded` and `guarded?` are
  removed.
* **Receiver kinds come from the reaching definitions.**
  `StaticDispatchRegistrations.receiver_kinds` asks
  `BytecodeIR.reaching_definitions(irep, index, reg, opaque_regs:
  BytecodeIR.own_upvar_written_regs(irep))` for each send. An opaque register
  refuses, so the send is `:unknown`. A send is `:self` for `SS*` ops, and an
  entry definition is `:self` only for R0. `register_kinds`, the `starts` set
  and `BLOCK_ENDERS` are removed. The APOST guard stays: an irep with an APOST
  gets no receiver facts, as before.

Guarded consumers (`guarded: true`, the codegen dispatch paths) keep the
join-blind walk. Their runtime class check covers a join, so their answers do
not change.

## Consequences

* Unguarded answers are refused where a join used to hide a second value. The
  refusals are the soundness fix; each one is a path that previously emitted a
  class-specific call or loop on an unproven fact.
* Callbacks that start a trace (`method_return_class`, `ret_class_proof`) now
  get an unguarded trace when they run inside a guarded one. Their answers can
  be refused where the guarded consumer used to accept them. That is the
  intended per-trace rule, not a change of the guarded contract.
* A receiver that the old whole-irep table called `:unknown` only because the
  send itself wrote R0 is not answered `:self` now (the entry definition is
  visible to the query only when no write reaches it). Nothing in the engine
  writes R0 this way.
* `receiver_kinds` refuses whenever `reaching_definitions` refuses (a protected
  range, a state cap, an unmodelled op). The old table answered those sends.
  Those sends now load as `:unknown`, which keeps more names dynamic, so the
  `STATIC_DISPATCH_UNREGISTERED` list can only shrink.
* The fixture is host only. The closed-world generated C++ was not diffed
  against master in this change (see the pull request for what was run).
  Follow-up: a closed-world diff of `build-closed-bc2cpp` against master, to
  record every changed call site.
* The `registry.rb` SETCONST caller of `literal_container_class` is unchanged.
  Its poisoning of disagreeing sites is what makes the fixed answer safe.
