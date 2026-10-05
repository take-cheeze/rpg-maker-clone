# ADR 0356: Readonly Ruby call effects in receiver flow

## Status

Accepted

## Context

NumericFlow widens every tracked ivar slot across a call because a callee may
write fields on the caller or another object. This discards an exact local store
even when stable closed-world lookup selects a getter that only reads values.

## Decision

Preserve ivar slot masks on the normal return edge of a zero-argument call when
all possible exact user receivers, bounded to eight classes, select stable Ruby
bodies with no arguments, nested ireps, or exception handlers. The complete
opcode whitelist admits only ENTER, register moves, self/nil/boolean/integer
loads, ivar reads, returns, and branches with a resolved control-flow graph.
No call, object allocation, write, captured read, or unrecognized opcode is
admitted. Native implementations are not summarized by this extension.

The receiver oracle supplies self for implicit sends. Unknown receiver bits and
any unsummarized member of a receiver union withdraw the proof. Lookup retains
the ordinary closed-world outside-source, installation, and mixin exclusions.

Call register clobbering and provenance clearing remain unchanged. Exceptional
edges still widen all ivar slots. The local result flow retains its existing
receiver and return rules; this extension changes only the call's write effects.
`BC2CPP_READONLY_CALL_EFFECTS=0` disables the effect summary.

## Consequences

An exact ivar store can survive an intervening Ruby getter without assuming
that arbitrary callees or native methods are readonly. Source-shape checks,
generated withdrawal cases, interpreter parity, and mutation checks enforce the
boundaries, including normal provenance and exceptional-edge invalidation.
