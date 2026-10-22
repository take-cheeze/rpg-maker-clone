# 0541. Share numeric-flow states across unchanged scalar results

Date: 2026-10-22

## Status

Accepted

## Context

After sharing unchanged literal loads (ADR 0536), transfer instrumentation still
observed repeated scalar writes whose masks and metadata already matched their
outputs. Constants, unknown results, collection builders, arithmetic and index
operations contribute most of these copies. MOVE contributes fewer unchanged
copies and has additional alias/class-test rules.

## Decision

Extract the existing scalar-result mask rules without changing their oracle
questions or ordering. The immutable per-Program step table records which
transfers only set their leading register. Solver-created contexts use the
existing unchanged-register-write checks for those results, including masks,
elements, provenance aliases and class-test invalidation. Still collect every
write union. Keep calls, MOVE, ivar reads and transfers that install class tests
or write additional registers on their existing paths.

A scalar operation may implicitly dispatch to Ruby. If so, copy a shared state
before the existing slot/provenance/class-test invalidation; an unchanged
result does not establish that a call preserves other facts.

Manual and Hash contexts retain copied results. The step flag contains bytecode
facts only; it neither caches oracle answers nor shares states between runs.
`BC2CPP_NUMERIC_RESULT_COPY_ELISION=0` disables the result-sharing decision.

## Consequences

More repeated scalar writes can reuse read-only states. Eligibility uses the
same metadata invariant as literal loads. A predecoded boolean avoids adding a
set lookup to every transfer. Mask rules remain in one method shared by the
copying and sharing paths.

The standalone host check compares 560 scalar transfers over wide/negative
masks and varied metadata, including write unions and oracle logs. It explicitly
checks quiet-constant sharing and copying before silent-call invalidation. The
pipeline comparison toggles result sharing while comparing complete facts,
receiver rows and diagnostics.

A warmed same-worktree Ruby 4.0.5/YJIT full-engine comparison on base
`4ccd606d` used the original source as baseline, including the dispatch
refactor's overhead in the optimized measurement. Allocations fell from
88,001,416 to 87,685,717 (315,699 fewer, 0.36%); complete facts, receiver rows
and report JSON were byte-identical. One object-profiled timing pair was
52.381s versus 51.253s, which does not establish a stable wall-time speedup.
