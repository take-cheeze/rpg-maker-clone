# 0501. Constant facts come from the bytecode IR

Date: 2026-10-19

## Status

Accepted. Stage 1 (report-only) and stage 2 (the IR decides the constant sets) are in this branch. Stages 3 and 4 are
listed under Consequences.

## Context

bc2cpp proves facts about constants (class, exact value, Fixnum interval) with several walks that
each read the bytecode on their own: IntegerConstants (bare-name walk_writers), IntegerConstantRanges,
DeclaredConstants (its own evaluator), the frozen-table path and native constructor facts. The
BytecodeIR reaching-definitions layer already decodes GETCONST, SETCONST, GETMCNST and LOADL, but its
type layer only types literals and element bounds. Each walk has its own soundness argument, and their
results can drift apart.

## Decision

Add `BytecodeIR::ConstantFacts` (tools/bc2cpp/bytecode_ir_constants.rb). For every SETCONST and
SETMCNST it takes the reaching definitions of the source register (BytecodeIR::Program#reaching_definitions)
and turns each writer into a node: an Integer literal, a non-Integer literal class, an alias
(GETCONST/GETMCNST of a bare name) or an integer operator over two alternative lists. Facts are:

- keyed by the full lexical path of the binding (the registry's constant sites), and
- read by bare name: a group is every binding of one bare name, and each fact kind (class, value,
  interval) is a least fixpoint over the group.

A bare name with a CLASS/MODULE of the same name or a native or foreign Ruby definition has no fact.
Values and intervals are bounded by the Fixnum margin. An out-of-margin literal or intermediate is an
Integer class with no value and no interval, so it is never folded as an immediate.

Stage 1 only reports the facts (`== BYTECODE_CONSTANT_FACTS (report-only)` in the bc2cpp log, lines
`IR_CONST` and `IR_GROUP`). The existing proofs still decide the build.
scripts/bc2cpp/ir_constant_facts_compare.rb compares the two.

## Consequences

- Stage 1, measured on the closed engine (type_check run with --keep): the IR gives 1034 paths and 913
  bare names. Against INTEGER_CONSTANT_PROOF, VALUE and NUMERIC_CONSTANT_RANGES there are no interval
  disagreements. The disagreements are:
  - value (12): a self-alias cycle (`ARROW_W = Window::ARROW_W`, next to `Window::ARROW_W = 16`). The
    proof does not drop the self-alias, so it gives up. The IR drops it, as IntegerConstantRanges
    already does, by the same induction on assignment order.
  - admitted-only-in-IR (18): names that NUMERIC_CONSTANT_RANGES already types as Integer.
  - class (93): `.freeze`d literal Arrays and Hashes (86), and constructed RGSS::Color and RGSS::Rect
    values (7). The IR does not model `.freeze` or constructors yet.
- Stage 2: the IR decides three constant sets. CodeGen's Fixnum-admitted names (`integer_constants`) are the IR
  groups with class Integer and an exact value or an interval, so every name is inside the Fixnum margin.
  `integer_constant_values` (the GETCONST/GETMCNST fold) and `integer_constant_ranges` (the NUMERIC_CONSTANT_RANGES
  intervals) are IR facts too. Integer `.freeze` is an identity under the stock-freeze gate. On the engine the
  admitted set goes 722 to 735 names, the folded values 689 to 701, the intervals stay 735. The RPG2k generated
  code gains 62 folded constant reads (`mrb_fixnum_value`), and loses 7 symbol-table entries. The RGSS, LCF and
  core generated code is unchanged. Not switched in this stage: the class masks of the class pools and the frozen
  table slots (still their own walks; they read the IR set only for the Integer test); the container and
  constructed-class hints (`container_constants`, the proofs' class facts); and DeclaredConstants' evaluator.
- Stage 3 (not in this change): remove the proofs that the IR replaces. The audit of what can go is ADR 0533; no code was removed.
- Stage 4 (not in this change): type check reads the IR facts as its constant rows.
