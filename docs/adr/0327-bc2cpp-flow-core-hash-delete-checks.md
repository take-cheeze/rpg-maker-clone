# 0327. Cover the flow-proven Hash#delete core path in the core-exact check

Date: 2026-10-03

## Status

Accepted

## Context

ADR 0325 measured six RPG2k and two LCF `Hash#delete` calls whose receivers
are proven exact by class flow but still dispatch by name. ADR 0323
(FLOW_CORE_DIRECT, `flow_core_direct_line`) resolves such sites before the
user-class polymorphic chain, which removes those sends. This ADR was first
written with its own copy of that lever; with 0323 merged it adds only the
coverage below.

Once the early return exists, the late `CORE_EXACT_DIRECT_NOTE` guard in
`compile_send` is unreachable, so the mutant that removed it survived. Mutating
the early return instead is only killed when a project class also defines the
name, because otherwise the poly path yields the same direct call.

## Decision

No generator change. `scripts/bc2cpp_core_exact_direct_check.rb` gains:

- fixtures for pooled Hash `delete` and `fetch` and a Hash-or-nil receiver,
  with runtime comparison against interpreted mruby (absent keys included);
- two project classes defining `delete` (`CxDeleter`, `CxDeleter2`), listed in
  `FIXTURE_OWNERS`, so the sites have a poly chain to skip;
- assertions for the kill switches (`BC2CPP_CORE_EXTEND=0`, class pools off) and
  a Hash override;
- the mutant "a flow-proven core receiver is not resolved ahead of the poly
  chain", replacing the one that mutated the now-dead guard.

## Consequences

The Hash#delete flow-core path of ADR 0323 is pinned by assertions and its
early return has a killing mutant. The measured effect of removing the eight
sends belongs to ADR 0323, not to this change.
