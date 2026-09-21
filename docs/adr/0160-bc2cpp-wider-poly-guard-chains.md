# 0160: bc2cpp guarded devirtualization for larger polymorphic families

Date: 2026-09-20

## Status

Accepted

## Context

`bc2cpp` already devirtualizes a polymorphic call by checking the receiver's
exact runtime class, calling that class's compiled method when it matches, and
falling back to `mrb_funcall` otherwise. This path was limited to at most five
eligible definitions. The whole-program dynamic-dispatch census includes
families larger than five, including 16 `dispose` definitions. Those calls
could use the same runtime guard without changing Ruby dispatch semantics.

## Decision

Raise `POLY_SMALL_N_MAX` from 5 to 16. Candidate eligibility remains unchanged:
each direct target must compile cleanly, have the call site's exact mandatory
arity, avoid native argument conversions, and be emitted by this bc2cpp run or
an explicitly trusted companion run. Every class without a matching candidate
continues through ordinary `mrb_funcall`.

A single eligible target is useful when the other definitions are native-only,
unclean, or outside the current emitted owner set: the exact class guard selects
the compiled target and all other classes retain normal dynamic dispatch.

The 16-owner limit covers the observed `dispose` family. The 21-owner `update`
family remains on dynamic dispatch, keeping generated code bounded where a
long chain of class comparisons is less attractive than mruby's method lookup.

## Consequences

- Polymorphic calls with 1–16 eligible compiled targets can now emit guarded
  direct calls.
- Calls with no eligible target or more than 16 eligible targets keep their prior
  dynamic-dispatch path.
- The generated code grows with the number of eligible targets. The fallback
  preserves behavior for unlisted classes, singleton methods, and targets
  that cannot be compiled safely.

## Addendum: accessor candidates

`attr_reader`/`attr_writer`/`attr_accessor` definitions (registry entries with
`kind: :ivar_accessor` and no irep) now join the chain as exact-class-guarded
`mrb_iv_get`/`mrb_iv_set`, the same lowering IVAR_ACCESSOR_DEVIRT already uses
for a traced receiver. Only the accessor's real arity is accepted (0 for a
reader, 1 for a writer). An owner that defines the name more than once (for
example an `attr_reader` redefined by a `def`) is excluded, because definition
order decides which body is live. Any other class still falls back to
`mrb_funcall`, so the total dynamic call-site count is unchanged; the sites are
reclassified from POLY to POLY_SMALL_N.
