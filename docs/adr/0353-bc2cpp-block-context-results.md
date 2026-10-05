# 0353. Admit blocks in call-context return analysis

Date: 2026-10-05

## Status

Accepted

## Context

ADR 0351 rejects every method with a nested irep. A block whose result is
ignored can therefore erase an otherwise exact identity or forwarding result.
Removing that exclusion alone would miss nonlocal returns from nested blocks
and permit an incorrect exact receiver at the caller.

## Decision

Analyze the method frame with the existing call-input context and captured-write
exclusions. Require the captured-local audit to exclude reflective local
writers whenever the body contains a nested irep. Before joining its reachable
returns, join every nested RETURN_BLK using independent block flows. Unknown or
unmodeled block returns prevent an exact result. The walk includes blocks at every depth and
lambda returns, so it may overapproximate exits but never drops a possible exit.

Caller argument and receiver masks are never seeded into block argument or self
registers. A block GETUPVAR reads the defining context's state at block creation,
joined with every later parent store, as in ADR 0308. Parent frames at every depth
are analyzed before their children. Captured registers with nested writes remain
unknown; absent or unmodeled defining contexts contribute OTHER. These states
and store summaries stay local to the call analysis and never enter global pools.
Block self remains unproven unless an independent existing flow establishes it.

A BREAK exits the block-taking call, not the containing method. Existing SENDB
result analysis remains responsible for that result; this change does not assume
that a block executes or that its normal result is the method result. Existing
closed-world target selection and recursion exclusions remain in force.

BC2CPP_BLOCK_CONTEXT_RESULTS=0 restores the nested-irep exclusion for comparison.
BC2CPP_CALL_CONTEXT_RESULTS=0 disables the whole call-context path as before.

## Consequences

Identity helpers containing ordinary blocks, same-class nonlocal returns and
discarded breaks can retain exact caller receivers. Read-only captured arguments
can retain their caller class through nested nonlocal returns. Captured writes,
unknown captures, mixed or nilable exits and unmodeled blocks stay conservative.
No method body or runtime dispatch semantics changes.

The focused fixture compares interpreted and compiled results. Sixteen
condition mutants include omission of nested returns, captured-write exclusions,
the block-analysis switch, capture context and later parent stores. Differing
exits at nested depths remain dynamic.

## Measurement

With identical Wio inputs on base c7e8cee8, enabling and disabling block contexts
produce byte-identical shipped C++. Both contain 2,785 cached calls (2,368 plain
sends and 417 block calls) and 911 POLY sites. The focused fixture proves new
receiver chains, including read-only captured arguments, but this extension
alone removes no shipped fallback. Further block-result or container analysis
is needed to connect these facts to the current workload.
