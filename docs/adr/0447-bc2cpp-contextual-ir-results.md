# 0447. Bounded contextual IR result summaries

Date: 2026-10-14

## Status

Accepted

## Context

Whole-method return unions lose information when an identity or builder method
is called with a known argument. Opaque calls also discard ivar facts even when
their Ruby bodies only read state. Native expression templates already contain
some result evidence that reporting does not expose.

## Decision

Run a separate reporting oracle over NumericFlow, specializing stable Ruby
targets by receiver and argument masks. Solve recursive contexts monotonically
with a private bottom value, and publish only completed graphs within fixed
budgets. Bind optional and direct keyword slots explicitly. Preserve ivar slots
only through transitively audited read-only Ruby bodies, and retain elements
only for fresh frozen builders. Audit native expression result constructors
under the existing native identity gates.

Keep declared optional, keyword and iterator element bounds separate from
independent proofs. Export their provenance and native form inventory through
the feedback report and RBS suggestions.

## Consequences

Caller-specific returns and some frozen container reads become reportable
without changing optimizer dispatch. Recursive unknowns and exhausted graphs
remain unknown. Mutable containers, opaque effects, splats and nonlocal block
exits still require additional models. Context and shape caches add bounded
analysis cost; diagnostic switches allow controlled comparisons.
