# 0440. Bytecode IR value-class inference

Date: 2026-10-14

## Status

Accepted

## Context

General IR optimizations need shared value facts through branches and loops.
Existing whole-program and code-generation proofs have different contracts;
reusing a textual previous writer would miss alternate definitions.

## Decision

Add `BytecodeIR::Types`, a query layer over the shared reaching-definitions
analysis with origin transfers enabled. Classify audited literal producers
and ENTER-created values and union all reaching classes. An unknown producer
or refused query makes the entire answer unknown. Use symbolic value classes
and immutable query results, without introducing annotation assumptions or
changing code generation.

Keep handler barriers, closure-write accounting and the existing traversal
budget. Distinguish Integer class facts from Fixnum or target-width proofs.
Calls and overloaded arithmetic require later identity/effect proofs before
their results can be classified.

## Consequences

Analyses gain a conservative common foundation for local value types without
another CFG or transfer model. Existing IR checks cover joins, loops, MOVE,
ENTER, pool kinds and refusal paths. No performance change is claimed until
a consumer uses these facts with its own soundness conditions. Call summaries,
entry contracts, finite values, element types and exception-flow propagation
remain follow-up work.
