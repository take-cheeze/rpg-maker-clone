# Integer fast arms for `==`, `!=` and `%`

bc2cpp arms compute Integer results inline, ahead of the generic paths
that stay in place for every other operand. All three are checked by
`scripts/bc2cpp/integer_fast_arms_check.rb`, which compares interpreted and
compiled runs.

## `==` (INTEGER_PAIR_EQ, `compile_cmp` in tools/bc2cpp/codegen_insn.rb)

`OP_EQ` used to start with an out-of-line `mrb_obj_eq` call, even for two
Integers. For Integers, `mrb_obj_eq` is the same as comparing their values. So
the compiled code now checks for an Integer pair first and compares the values
directly. Every other operand still goes through identity, the Symbol shortcut
and the numeric/`==` chain, in the same order as before.

## `!=` (NEQ_INTEGER_PAIR)

The Integer-pair arm for `!=`, with its `integer_eq_native?` proof, is
described in [bc2cpp-array-write-inline.md](bc2cpp-array-write-inline.md).
This page's check still runs `!=` over the same operands, in a default world
and in one that reopens `Integer#==`.

## `%` by a constant power of two (MOD_POW2_CONSTANT, FIXNUM_BINARY in tools/bc2cpp/codegen_send.rb)

Ruby's floor modulo by a positive `2**k` is `x & (2**k - 1)` for either sign
of `x`. The fixnum arm tests `__builtin_constant_p(divisor)`, so the C++
compiler keeps the mask only at sites where the divisor is a known constant
(`@hclk % 8`). At every other site the test folds away and the general floor
modulo runs.

## Effect

On the optcarrot probe (Lan_Master, callgrind, frames 2–21), the three arms
together took per-frame instructions from 54.76M to 50.40M (−8.0%). `!=`
accounted for about −3.9M of that and now lands with the array write fast
paths; `%` accounted for about −0.5M.
