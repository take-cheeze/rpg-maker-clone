# Integer fast arms for `==`, `!=` and `%`

Three bc2cpp arms compute Integer results inline, ahead of the generic paths
that stay in place for every other operand. All three are checked by
`scripts/bc2cpp/integer_fast_arms_check.rb`, which compares interpreted and
compiled runs.

## `==` (INTEGER_PAIR_EQ, `compile_cmp` in tools/bc2cpp/codegen_insn.rb)

`OP_EQ` used to start with an out-of-line `mrb_obj_eq` call, even for two
Integers. For Integers, `mrb_obj_eq` is the same as comparing their values. So
the compiled code now checks for an Integer pair first and compares the values
directly. Every other operand still goes through identity, the Symbol shortcut
and the numeric/`==` chain, in the same order as before.

## `!=` (NEQ_INTEGER_PAIR, `integer_eq_native?` in tools/bc2cpp/codegen_native_send.rb)

`!=` compiles to `!mrb_equal(a, b)`. When the two Integers differ,
`mrb_equal` falls through to `mrb_funcall(a, :==, b)`, which costs several
hundred instructions to return `false`. The compiled code now compares two
Integers directly, but only if the closed world proves that `Integer#==` is
still the native `int_equal`. That proof needs all of the following:

- there is no Ruby `Integer#==`;
- no module is prepended to Integer and Integer has no unresolved mixin;
- nothing installs a `==` dynamically.

If any of these fails (for example, a program reopens `Integer#==`), the
site keeps the plain `!mrb_equal` call.

## `%` by a constant power of two (MOD_POW2_CONSTANT, FIXNUM_BINARY in tools/bc2cpp/codegen_send.rb)

Ruby's floor modulo by a positive `2**k` is `x & (2**k - 1)` for either sign
of `x`. The fixnum arm tests `__builtin_constant_p(divisor)`, so the C++
compiler keeps the mask only at sites where the divisor is a known constant
(`@hclk % 8`). At every other site the test folds away and the general floor
modulo runs.

## Effect

On the optcarrot probe (Lan_Master, callgrind, frames 2–21), per-frame
instructions fall from 54.76M to 50.40M (−8.0%). Of that, `!=` accounts for
about −3.9M (most of it the `@hclk != 255` test in `PPU#main_loop`), and `%`
for about −0.5M.
