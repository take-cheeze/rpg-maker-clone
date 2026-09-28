# 0243. bc2cpp resolves division from a float literal receiver

Date: 2026-09-28

## Status

Accepted

## Context

The bytecode `DIV` fast path handles Integer and Float operand pairs. Its
remaining operand shapes use a normal `/` send. For a receiver loaded directly
from an mrbc Float pool entry, that fallback is unnecessary: `LOADL` creates an
immediate Float and Float#`/` is the native implementation, provided the
closed-world registry has no Float override or prepend.

## Decision

Follow only `MOVE` instructions from a `/` receiver to its defining `LOADL` and
confirm the referenced pool entry is a Float. Under the existing native-owner
safety check, emit the Float division body directly using `mrb_as_float` and
`mrb_div_float`. With `MRB_USE_COMPLEX`, preserve Float#`/`'s Complex special
case through ordinary dispatch; all other argument conversions follow the
native body.

## Consequences

Float-literal receiver sites no longer retain a dynamic fallback for
non-Complex operand shapes. Any intervening write, non-Float pool entry,
overridden Float#`/`, or prepended module keeps ordinary dispatch.
