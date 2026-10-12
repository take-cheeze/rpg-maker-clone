# 0414. Compact resumable register frames

Date: 2026-10-12

## Status

Accepted

## Context

Resumable step functions previously reserved every register up to the largest
`rNN` occurrence in generated text, including comments and string contents,
and at least the original bytecode register count. Diagnostic method names
could therefore reserve thousands of unused references and GC-visible frame
cells. Inlined helper offsets also leave gaps in the register numbering.

## Decision

Discover register identifiers after skipping generated C++ quoted strings,
character literals, raw string literals and comments. Give each referenced register one dense
frame slot, ordered by its original register number, and always include `r0`
for the step function's self assignment. Preserve the two leading cells for
yielded and resumed values.

Generated step bodies access ordinary registers through their `rNN` aliases;
only yield and resume access `R[0]` and `R[1]` directly. The alias mapping can
therefore change without rewriting the body or changing suspension state.
The scanner also skips C++ raw string literals using their exact closing
delimiter, so embedded quotes cannot expose register-like contents.

## Consequences

Unused registers do not allocate references, heap cells or GC scan work.
The independent Fiber fixture compares interpreted and compiled execution
under ordinary GC, incremental GC stress and lazy driver initialization.
Synthetic assembly checks cover sparse register numbers and register-like
text inside escaped strings, character literals, raw string literals and comments.

This does not change yielding-helper expansion or the depth bound. Sharing
those helpers still needs a representation that preserves suspended state.
