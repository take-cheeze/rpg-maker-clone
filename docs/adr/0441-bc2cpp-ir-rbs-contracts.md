# 0441. RBS nominal contracts in bytecode IR

Date: 2026-10-14

## Status

Accepted

## Context

The initial IR type query knows literal producers but cannot type incoming
arguments. The RBS loader previously retained nullable, union and boolean
syntax only as text because the older optimization hints cannot express it.
Treating an RBS class as an exact inferred receiver would be unsound: nominal
types admit subclasses and declarations depend on callers honoring contracts.

## Decision

Retain a separate nominal value-class projection on parsed RBS types. Support
named classes, Array/Hash outer classes, optional types, unions, booleans,
nil and literal classes. Any unsupported union member poisons the projection.
Do not change the existing hint kinds or generated code.

After matching method definitions and required arity, record required argument
contracts by IREP and register, excluding comment-owned slots. Provide
`RbsSignatures.ir_types` and `BytecodeIR::Types#fact_at` for contract-aware
queries. Facts and their class sets are immutable; a declared flag propagates
through unions whenever any source relies on a contract. Keep `#at` restricted
to inferred facts and retain all shared reaching-definition refusal rules.
Present the richer argument declarations in type-check facts with source
`signature`, separately from inferred types.

## Consequences

IR analyses can inspect richer RBS argument bounds through MOVE, branches and
loops without mistaking them for exact-class or representation proofs. These
contracts do not yet resolve calls or add runtime enforcement. Optional, rest,
post, keyword, block, ivar and return contract propagation remain follow-up
work. Existing hint contradiction checks are unchanged; the richer declarations
are reported, not newly validated against all possible callers.
