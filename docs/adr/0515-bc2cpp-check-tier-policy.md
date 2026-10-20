# 0515. Describe check prerequisites separately from execution lists

Date: 2026-10-20

## Status

Accepted

## Context

The registration audit had string-only deferral reasons and a hard-coded MRBC
gate list. A coverage invocation could exercise only a host slice while a moved
fixture invocation lost the compiler setup it needed.

## Decision

Keep workflow commands and the coverage reporter as execution sources. Add a
versioned policy to the check policy YAML with explicit tiers, capabilities,
runner provisions and inspected active-check metadata. Separate the host
requirements from additional fixture requirements. Validate compatible placement
and require a complete fixture invocation without scheduling extra work.

## Consequences

Deferrals become inspectable by purpose and prerequisites, and stale entries fail
the audit. Runner provisions must stay synchronized with setup changes. Active
checks without inspected metadata fail the audit. Metadata covers a supported
configuration rather than every optional platform variant. See `docs/bc2cpp-check-tiers.md`.

Optional fixture gaps require an explicit exemption and reason and remain visible
in the report. A classified fixture gate is required by default.
