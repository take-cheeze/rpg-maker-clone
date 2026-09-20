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

The 16-owner limit covers the observed `dispose` family. The 21-owner `update`
family remains on dynamic dispatch, keeping generated code bounded where a
long chain of class comparisons is less attractive than mruby's method lookup.

## Consequences

- Polymorphic calls with 6–16 eligible compiled targets can now emit guarded
  direct calls.
- Calls with fewer than two or more than 16 eligible targets keep their prior
  dynamic-dispatch path.
- The generated code grows with the number of eligible targets. The fallback
  preserves behavior for unlisted classes, singleton methods, and targets
  that cannot be compiled safely.
