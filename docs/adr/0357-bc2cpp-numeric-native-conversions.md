# 0357. Audited direct calls for proven Integer conversions

Date: 2026-10-05

## Status

Accepted

## Context

Integer receivers proven by NumericFlow still retained runtime type guards and
cached dispatch fallbacks for zero-argument `to_s` and `to_i`. Exact core receiver
analysis covers containers and does not classify numeric masks.

## Decision

Use existing NumericFlow's exact Integer mask for ordinary explicit, unsubstituted
zero-argument sends. Require the closed-world singleton gate, exact native lookup,
stable method visibility, no blocked dynamic installer, unchanged registered
argument specifications and audited C function bodies.

Keep these entries separate from generic guarded native arms: admission uses
the numeric proof and its visibility and installer gates.

For `Integer#to_s`, call the public `mrb_integer_to_str` with radix 10. It accepts
both fixnums and bigints. For `Integer#to_i`, preserve the receiver, matching the
audited `mrb_obj_itself` body. Neither path converts a bigint to an `mrb_int`.
Keep nonzero arities, blocks, mixed numeric masks, unknown values and altered
method lookup on their previous paths. `BC2CPP_NUMERIC_NATIVE_DIRECT=0` disables
the new numeric proof route.

## Consequences

Existing numeric argument, ivar, return and local facts can eliminate conversion
fallbacks without introducing another receiver lattice. Audit failure withdraws
the optimization. Float conversion is not admitted: `mrb_float_to_integer` and
`Float#to_i` differ in their errors for NaN and Infinity, so using the public API
without further work would change observable behavior.

The parity fixture also runs against 32-bit and no-bigint libraries with
width-safe literal inputs and matching generated-code defines.
