# 0272. A block's store to a captured local roots the value

Date: 2026-09-30

## Status

Accepted

## Context

A block-fallback body reaches the enclosing method's locals through pointers into that
method's C++ frame (`*bc2cpp_upvar_N = r3`, the only emission site is `SETUPVAR`). The GC
cannot see the frame. A value the block creates is held by the arena, but mruby restores the
arena to the entry level after every block call and protects only the block's result, so a
String stored only in a captured local (`min_cmp = x.to_s` in `Enumerable#min_by`, never
reassigned) is collected mid-loop. `(1..300).to_a.min_by { |x| x.to_s }` on the compiled core
raised `comparison of String with String failed` under GC pressure; the interpreter did not.

## Decision

`SETUPVAR` also calls `bc2cpp_upvar_root(M, slot, value)`. For a heap value it records it in a
hidden hash (`$__bc2cpp_upvar_roots`) keyed by the slot's address (`slot >> 2`, a fixnum on
32-bit targets too), replacing the previous value of that slot. Immediates are skipped, so the
counter-style stores (`n += 1`) cost one type test.

## Consequences

- The set of roots is bounded by the number of distinct stack slots ever written this way, not
  by the number of stores. A dead slot keeps its last value alive until another frame reuses the
  address; nothing depends on finalisation timing of such values.
- The hash is an ordinary global, visible to `global_variables`.
- Fixes the `big min_by` difference of the block/Fiber probe in `core-mrbtest`.
- Not covered: a block's own registers across a nested block call (still arena-held for the
  duration of the outer block call, which is the whole lifetime of those registers).
