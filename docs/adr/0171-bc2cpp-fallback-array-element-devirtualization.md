# 0171: Carry Array element types into fallback block bodies

Date: 2026-09-21

## Status

Accepted

## Context

bc2cpp inlines some Array blocks and specializes calls on proven element types
there. Blocks that fail an inlining recognizer are compiled as standalone cfuncs;
that path previously discarded the receiver's element type, leaving calls in the
fallback body on ordinary Ruby dispatch even when its block came from a proven
Array.

## Decision

For a fallback block passed to zero-argument `Array#each` with one mandatory
block argument, reuse the compiler's Array receiver and element-class proofs.
Pass the element class to the existing per-instruction element hint while
compiling the standalone cfunc. The generated call still checks the yielded
object's exact runtime class and uses Ruby dispatch when it differs. Other
iterators and unresolved Array contents receive no hint.

## Consequences

Fallback bodies can specialize element calls without needing to inline the
whole loop. Whole-program output currently shows guarded element dispatch in 2
of 359 fallback bodies, covering 5 sends; this includes `Game::Party#cast_skill`
and `Game::Interpreter#do_change_condition`. The regression covers a typed
fallback, an untyped fallback, and the existing inlined path.
