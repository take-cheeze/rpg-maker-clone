# 0239. Branch on finite runtime-selected constructor classes

Date: 2026-09-28

## Status

Accepted

## Context

Some constructor receivers come from runtime data or a method result rather
than one constant expression. LCF chooses a root record class from a schema
type, and battle setup chooses an RPG2000 or RPG2003 scene class from the
database edition. Leaving both as opaque `new` sends prevented direct
construction even though their intended class sets are small and explicit.

## Decision

Use an explicit `case` for supported LCF root schema types and explicit class
identity branches for the two battle scene classes. Each branch uses a
statically named constructor so bc2cpp can apply its existing constructor
proofs.

## Consequences

The expected schema and battle paths no longer construct through a
runtime-selected class receiver. Unsupported LCF root types still raise
`NameError`.
