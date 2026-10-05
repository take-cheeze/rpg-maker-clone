# bc2cpp native int guards (ADR 0358)

An `:int` argument of a NATIVE_DIRECT_EXACT arm is passed to a native `mrb_int`, and
`mrb_integer()` raises on anything the binding's `mrb_get_args "i"` would have coerced. So the
arm carries a runtime `mrb_integer_p` test whose else is a by-name send.

That test is only needed when the argument can be something else, and the Fixnum proof
(`native_int_arg_proven?`, ADR 0318) already answers that question for integer constants and
for intervals of them. NATIVE_DIRECT_EXACT now asks it: a proven argument drops its test, and
with it the arm's only remaining dispatch.

The two emitters that already did this are `codegen_send.rb`'s `Bitmap.new` path (ADR 0318)
and `codegen_native_exact_direct.rb`'s NATIVE_EXACT_DIRECT. ADR 0358 adds the third,
`native_direct_exact_line`, reached from `native_direct_wrap`.

## What is and is not covered

The class-tested NATIVE_DIRECT arms are unchanged. They run only when no exact-core site
matched, so no proof is available for their arguments; a receiver the class flow proves exact
is routed to the exact line instead, where the test can be dropped.

`BC2CPP_NATIVE_INT_GUARDS=0` is the control: it restores every tag test.

## Checks

- `scripts/bc2cpp_native_int_guard_check.rb` pins the emitters' shape for every answer the
  proof can give (proven, unproven, no site, a proof for another position, a non-`:int`
  kind), drives the real `native_int_arg_proven?` over its own refusals, and generates code
  for a closed and an open world.
- `scripts/bc2cpp_native_int_guard_mutation_check.rb` weakens the gate, the switch, the
  proof's register test and the position argument in turn; each must be caught.

## Measured effect

Wio closed world, shipped pass, `BC2CPP_NATIVE_INT_GUARDS=0` against default on one tree:

| Measure | Control | Enabled |
| --- | ---: | ---: |
| `bc2cpp_send` call sites | 2,343 | 2,334 |
| `NATIVE_DIRECT_EXACT` arms keeping an `mrb_integer_p` test | 26 | 17 |
| `bc2cpp_getidx` / `setidx` / `slow_*` / `eqq` callers | unchanged | unchanged |

Nine `z=`/`x=`/`flash` sends are removed, not relocated: no helper gained a caller. The
remaining 17 are arguments the Fixnum proof does not cover.
