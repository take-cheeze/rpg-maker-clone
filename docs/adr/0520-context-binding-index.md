# 0520. Index context argument layouts by bytecode identity

Date: 2026-10-21

## Status

Accepted

## Context

Context evaluation repeatedly binds the same method with different receiver and
argument facts. Arity fields, keyword names and optional-argument jump layouts
come from unchanged bytecode, while the argument masks and selected entry edge
vary by context.

## Decision

Keep an identity-keyed layout index in each `IrContextResults` engine. Validate
and freeze arity fields, keyword names, required keyword names and ENTER offsets
once per body. Cache malformed-layout refusals because they depend only on that
body. Retain current argument-count and keyword checks on every binding, and
construct fresh argument masks and entry edges. No inferred values, graph
admissions or budget decisions enter this index.

The engine requires its bytecode bodies to remain unchanged. The index lifetime
ends with the engine and its size is bounded by the bodies queried in that world.
`BC2CPP_IR_BINDING_INDEX=0` rebuilds layouts for comparison runs.

## Consequences

Repeated context calls avoid bytecode scans and layout allocations. Fresh binding
state preserves optional argument selection, required/optional keywords, rest and
post arguments, and root-specific handling. Existing whole-report fixture
comparisons exercise enabled and disabled indexing, including solver limits.
