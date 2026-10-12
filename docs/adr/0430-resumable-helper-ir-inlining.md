# 0430. Yield-free helper IR inlining in resumable frames

Date: 2026-10-13

## Status

Accepted

## Context

The synchronous Optcarrot PPU source generator removes ordinary helper calls.
The existing bytecode IR method inliner refuses resumable contexts, so the
original Fiber PPU cannot benefit from equivalent helper expansion. Ordinary
C++ local registers cannot safely represent values live across a suspension.

## Decision

Behind both `BC2CPP_IR_INLINE=1` and `BC2CPP_IR_RESUMABLE_INLINE=1`, lower
same-owner yield-free `MethodInlineRegion` bodies inside the resumable step
function, using the ordinary method inliner's argument capture, return exits
and instruction lowering. Only the caller needs persistent registers: the
helper's non-suspension proof permits ordinary C++ locals. Rename helper-local
register identifiers outside literals and comments so resumable frame assembly
does not reserve heap slots for them. The caller's arguments are captured before
entering the callee scope, and its result is stored back into the caller frame.

Keep the method inliner's mandatory-argument, instruction, block/handler,
256-instruction and 128-register limits, two-level recursion bound and
512-instruction method budget. Refuse native argument signatures and any target
in the Fiber-unsafe set, calling Fiber.yield directly, or in the transitive
name-based yielding set. Existing call-selection guards remain in force.

## Consequences

The original PPU bytecode can avoid helper call overhead while keeping exact
per-yield continuation states and GC-visible caller registers. Native checks compare
both flag modes against the interpreter, including nested arguments, GC inside
helpers, caller values across later suspension, indirectly yielding helpers and
Fiber reentry. Nightly CI runs both modes. The probe uses a distinct binary
suffix and reports region counts.

The synchronous source generator remains a separate optimization. Replacing
the Fiber protocol itself would require proving its identity and observable
state cannot escape to CPU hooks or other code; horizontal clock values alone
are not unique continuation identifiers.
