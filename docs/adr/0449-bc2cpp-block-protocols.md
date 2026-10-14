# 0449. Separate block protocols, captures and generic callback contracts

Date: 2026-10-14

## Status

Accepted

## Context

Array iterator contracts supply block arguments but leave custom yield sites,
outer captures and generic RBS callbacks unknown. Combining these sources without
provenance would promote conditional signature bounds into independent facts,
and a callback type alone says nothing about whether a closure escapes.

## Decision

Use three reporting components: bounded pure custom-yield summaries under exact
target lookup, immediate capture summaries under explicit synchronous invocation
proofs, and nominal RBS callback type-variable substitution. Feed argument and
capture Facts into shared IR queries without discarding declaration provenance;
independent queries refuse declared Facts. Custom-yield summaries take precedence
over declared callback argument bounds and can reveal disjoint contracts.

Complete all block exits before reporting generic callback results. Use known
subtype relationships for callback checks, retaining unknown relations rather
than declaring a mismatch. Do not use these results for optimizer dispatch or
enclosing return export.

## Consequences

Literal block bodies gain independently typed custom-yield parameters, stable
captures and substituted generic callback results. Opaque effects, escaping
callbacks, nested environments, unresolved generics and unsupported invocation
shapes remain unknown. The checks include real mrbc fixtures and declaration
isolation tests, and each bridge has a diagnostic opt-out.
