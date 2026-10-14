# 0448. Generic iterator block feedback

Date: 2026-10-14

## Status

Accepted

## Context

Iterator feedback reports a declared Array element bound for a block argument
but does not analyze the block body or express its generic result relationship.

## Decision

Instantiate nominal Array iterator yield contracts at literal blocks and run
the shared bounded IR type queries on those bodies. Report individual block
facts with provenance, and substitute complete block return unions into the
conditional map/collect result. Each/each_with_index retain the receiver element
bound. Refuse normal iterator results for nonlocal exits, handlers or unknown
return facts. Keep these contracts separate from exact receiver proofs and
enclosing method inference.

## Consequences

Feedback exposes the T-to-U relationship without requiring one block annotation
per call. Literal block results can remain independent, while parameter-derived
results retain declaration provenance. Custom yield protocols, captured-variable
flow, arbitrary generic RBS functions and enclosing return export need further
models. Generated C++ remains unchanged.
