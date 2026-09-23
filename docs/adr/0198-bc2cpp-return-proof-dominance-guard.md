# 0198. bc2cpp RETURN-site proofs require a dominating write, not a join-free walk

Date: 2026-09-23

## Status

Accepted

## Context

ARRAY_RETURN_PROOF and RETCLASS_SELF_CALL_SUPPORT (ADR 0194) prove "every
RETURN of this MONO method yields class C". Both first run
`straightline_return_reg?`. It walked back from the RETURN along MOVE chains
to the returned register's writer and refused as soon as it crossed any jump
target. The target did not have to touch the traced register. So
`build_field_background` could not be proven: an unrelated `colour = if skin
... end` sits between `sprite = Sprite.new` and `RETURN sprite`. ADR 0194
lists this as follow-up (1).

An earlier proposal allowed crossing a jump target when the traced register
has exactly one writer in the method. That is unsound, and a real `mrbc`
build confirms it. Method entry is a second definition that no instruction
shows: nil for a local, the caller's value for an argument. With the
proposal, `x = Foo.new if c; bar; x` proved `Foo` (x can be nil). The same
happened for `def m(a = Foo.new); bar; a; end` and for `a = Foo.new if c`
on an argument.

Checking the old guard turned up two more holes it already had:

- A nested block can write the returned local with `SETUPVAR`
  (`x = Foo.new; [1].each { x = 1 }; x` proved `Foo`). This is why
  `LCF#encode_event_commands`/`encode_move_commands` were proven `String`,
  even though `out = out + ...` in a block reassigns `out`.
- The guard only covered the walk to the first writer. trace_new_target
  then went on, without any check, into a `.new`/`.dup`/accessor receiver. That
  receiver can be a local assigned on either side of an `if`, so
  `x = Foo.new; x = Baz.new if c; x.dup` proved `Baz`.

## Decision

Every hop must be a write that dominates the instruction that reads it.
The new `return_write_dominates?` reuses FIXNUM_OPERAND_PROOF's region test
(`fixnum_proof_region_ok?`). No edge into `(write, use]` may come from
outside that range. Every instruction stepped over must be on its audited
`FIXNUM_PROOF_STEP_OVER_OPS` whitelist, so writers the walk cannot see
(RESCUE's second operand, APOST, ...) cause a refusal. A register that a
nested block writes also causes a refusal.

- `straightline_return_reg?` applies this at each MOVE hop and at the final
  writer. It still refuses a walk that falls off the front of the method.
- The two callers pass the same test to `trace_new_target` as `dominated:`.
  Every deeper hop is then checked, including the fall-back to an annotated
  argument (`w_idx = -1`). Other callers pass nothing, so their output is
  unchanged.
- Block writes are found by a level-aware `own_upvar_written_regs`: a
  `SETUPVAR` `d` blocks down names this frame only when its level is `d - 1`
  (`uvenv` in vm.c). `subtree_upvar_written_regs` ignores the level. With it,
  an inner block's `sp += dsp` would block `apply_map_step_damage`'s `hit`.
- The nine read-only opcodes are now a single `READ_ONLY_OPCODE_SKIP`
  constant, shared by both backward walks and the new guard.

## Consequences

Measured with `scripts/bc2cpp_coverage_report.rb` (whole program) before and
after:

- ARRAY_RETURN_PROOF 113 -> 131 (+18, none lost).
- RETCLASS_SELF_CALL 145 -> 182 (+39). Two were lost: `encode_event_commands`
  and `encode_move_commands`, which are the closure-write hole above.
- CLASS_HINT 268 -> 273: the five `@background` ivars now resolve to
  `Sprite`. OPAQUE ivar candidates 507 -> 502.
- BLOCK_FALLBACK 360 -> 358: two blocks become inlined collect loops on
  receivers now proven Array.

Everything else in the report is unchanged. The check against a join-free
walk is gone. A join is now accepted when control cannot reach it
without passing the write, as in a loop between the write and the RETURN, or
a RETURN on a loop-exit label. `scripts/bc2cpp_return_join_check.rb` checks
the accepted shapes and every refused one: the nil local, the optional and
reassigned arguments, the `||` join, a write inside the loop body, block
writes at depth 1 and 2, and the `.dup` join.
