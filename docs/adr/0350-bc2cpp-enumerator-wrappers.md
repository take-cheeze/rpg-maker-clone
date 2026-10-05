# 0350. Compile guarded Enumerator wrappers

Date: 2026-10-05

## Status

Accepted

## Context

The blanket exclusion of mruby-enumerator keeps small wrapper methods interpreted
along with bodies that create closures or suspend Fibers. A wrapper can delegate
to a callback that yields even when its own bytecode contains no block operation.

## Decision

Admit only Enumerator's `inspect`, `size`, `rewind`, `feed`, `next`, `peek` and
`peek_values` from the canonical mruby-enumerator source. Analyze each actual
body and reject block operations, lambdas and references to Fiber. Existing
conditional, replacement and explicit refusal exclusions still apply.

Every admitted entry checks `M->c != M->root_c` and executes its saved bytecode
through `bc2cpp_core_interpreted` inside a Fiber. Registration saves the original
RProc before replacing the method. The existing saved-proc table anchors it for
GC. These definitions remain hidden from direct dispatch, and
`core_body_relaxable?` always refuses their guard relaxation or direct body calls.

`BC2CPP_ENUMERATOR_WRAPPERS=0` restores the previous exclusion.

## Consequences

Seven more methods can execute compiled code in the root context. Suspension
continues through the interpreter inside Fibers; this introduces no compiled
closure or resumable native frame support. Compiling these methods also exposes
their delegated dynamic sends in generated-code counts.

The focused check covers root execution, yielding callbacks, peek/feed/rewind
state, StopIteration, argument errors, subclass overrides and GC. Generated-code
checks enforce registration, guards and absence of direct body callers. Seven
mutants withdraw individual admission and guard conditions. The existing full
mruby suite and Fiber probe compare interpreted and compiled behavior.
