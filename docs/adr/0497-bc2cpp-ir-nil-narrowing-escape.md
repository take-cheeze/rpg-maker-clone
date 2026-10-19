# 0497. NIL_NARROWING and ESCAPE_ANALYSIS run on the bytecode IR

Date: 2026-10-19

## Status

Accepted

## Context

NIL_NARROWING (ADR 0456) is a forward must-analysis over the IR's CFG, but to
narrow the local a tested register was copied from it walked raw instructions
backward (`copy_source`: up to 64 instructions, one MOVE hop, then
`write_dominates?` and a linear scan for writes of the source). That walk
missed copy chains, sibling copies and copies that reach a test through a
join, and duplicated in instruction order what a dataflow state can carry.

ESCAPE_ANALYSIS (ADR 0316) already flowed values over the IR's successors and
handler edges, but scanned `irep.instructions` for closures, definitions,
block pushes and upvar reads.

## Decision

* NIL_NARROWING carries **available copies** in its must-state: `MOVE d s`
  adds `[:copy, d, s]` and `d` paired with every copy of `s`; a write of
  either register (`Program#may_write_at?`) drops the pair; a join keeps the
  pairs every edge has. A test or a call that proves `r` non-nil (or an
  `is_a?` guard that proves its class) proves every register paired with `r`.
  Branch kinds and targets come from `Program#decoded`. `copy_source`,
  `COPY_WINDOW` and the legacy walk are removed.
* `Program#may_write_at?(index, reg)` is added to `bytecode_ir_dataflow.rb`:
  `may_write?` from the walk's per-instruction effect table.
* ESCAPE_ANALYSIS's op scans read `Program#each_with_op`
  (`EscapeAnalysis.op_sites`), and single instructions
  `Program#instruction_at`.

## Consequences

* NIL_NARROWING proves a superset of what it proved: on the engine and mruby
  core image, 0 facts lost and 2014 gained (docs/bc2cpp-ir-nil-escape.md).
  More RBS_CHECKED_PARAMS parameters can be kept; none can be lost.
* Soundness rests on the copy pairs being killed by every possible write,
  which is `may_write_at?`'s model (a callee frame, an unmodelled op, a
  nested block's SETUPVAR register, which never enters a pair).
* ESCAPE_ANALYSIS answers are unchanged (the scans return the same sites).
* Operand decoding still reads the instruction's `source`; the IR has no
  operand model yet.
