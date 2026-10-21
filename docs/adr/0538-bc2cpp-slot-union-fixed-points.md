# 0538. Reuse numeric-flow ivar slot union fixed points

Date: 2026-10-22

## Status

Accepted

## Context

Every call that can write ivars widens their tracked masks with the oracle's
per-slot fact. Repeating the same union allocates another wide integer even when
it cannot change the mask. Full-engine allocation sampling attributed about
780,000 allocations to these unions.

## Decision

A solver-created numeric-flow context retains the last union result per slot.
Its slot facts are established once at run entry. A mask equal to that result,
or to the slot fact itself, is already a fixed point under union with that fact.
Skip only that union, retaining all provenance and class-test invalidation.
Only integer masks use the shortcut; malformed standalone inputs keep their
existing results or exceptions.

The cache retains at most one mask per slot. It is local to the run and cannot
leak facts between oracles, compiler instances or layouts. Hash/manual transfer
contexts keep unconditional unions because their fact arrays can be mutated.
`BC2CPP_NUMERIC_SLOT_UNIONS=0` disables reuse for differential validation.

## Consequences

Repeated call invalidation avoids wide integer allocations without skipping any
oracle questions or state transfers. Changed slot values still undergo the
original union before replacing the cached fixed point. The host check compares
states, writes and oracle ordering with reuse disabled for wide and negative
masks, preserves malformed-input behavior, and checks mutable standalone facts.
The existing pipeline comparison toggles reuse while comparing complete facts,
receiver rows and diagnostics.

A warmed same-tree Ruby 4.0.5/YJIT comparison reduced allocations from
94,470,336 to 93,784,651, saving 685,685 objects (0.73%). Complete facts JSON,
receiver TSV and diagnostic JSON were byte-identical. Profiled times were
52.05s and 52.79s in one pair, so this does not establish a wall-time speedup.
The comparison used StackProf object sampling at one allocation in 4096 after
a discarded cache-warming run.
