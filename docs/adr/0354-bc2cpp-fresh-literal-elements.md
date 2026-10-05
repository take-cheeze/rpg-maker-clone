# 0354. Prove elements of immediate fresh array reads

Date: 2026-10-05

## Status

Accepted

## Context

Array element hints cannot remove fallback dispatch: a mutable container may
change through an alias. Whole-program mutation and escape summaries are not
available for arbitrary containers.

## Decision

Add a bounded local proof for `GETIDX` and `GETIDX0` immediately following a
fresh `ARRAY` or `ARRAY2`, with only an integer literal index load between them.
The index must be in bounds. Recover the selected element from its preceding
primitive literal instruction through a linear corridor containing only literal
loads and fresh array construction. Refuse captured-write registers, handlers,
unknown values, calls, branches entering the corridor, moves, mutations and
escapes. Search at most 32 instructions.

The proof yields Integer, String, nil or Array masks to NumericFlow. It does
not turn mutable element hints into exact facts and does not change generated
indexing semantics. `BC2CPP_LITERAL_ELEMENT_PROOF=0` withdraws the new facts.

## Consequences

Immediate literal chains can use existing native or numeric direct arms.
The proof introduces no mutable container facts into pooled arguments or ivars.
It deliberately rejects user class constructors, hash lookups and arrays kept
in locals. Expanding these cases requires separate alias, lookup and mutation
proofs. Runtime parity and mutation checks cover the admitted and refused shapes.
