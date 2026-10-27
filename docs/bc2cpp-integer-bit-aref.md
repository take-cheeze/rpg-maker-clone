# bc2cpp: `n[i]` on a Fixnum as an inline bit read

`INTEGER_BIT_AREF` (`tools/bc2cpp/codegen_integer_bit_aref.rb`) reads a bit
inline for `x[i]` (GETIDX) when `x` is a Fixnum. Before it, such a read took
`bc2cpp_getidx_slow`: the Array, Hash and String tests, then the
`POLY_SMALL_N` chain, then a call into the compiled `Integer#[]`.

mruby has no `Integer#[]`. A program that needs one defines it in Ruby, as
optcarrot's probe does (`tools/optcarrot_probe/shim_integer_aref.rb`):

```ruby
class Integer
  def [](i)
    (self >> i) & 1
  end
end
```

The optcarrot benchmark reads bits this way in `CPU#branch`, `CPU#_cmp` and
the LUT initializers (`PPU::TILE_LUT` alone reads 4.3 million bits at startup).

## When the arm is used

The arm is emitted only when the closed world shows that a Fixnum's `[]` runs
exactly this body:

- the program has exactly one `Integer#[]`. It is a public Ruby `def`, not an
  alias, a `define_method` or a runtime installer, and `[]` is not blocked by
  `RUNTIME_DEF_DEVIRT_GUARD`;
- nothing is prepended into `Integer`, and `Integer` has no unknown mixin;
- the definition's bytecode is the body above: one required argument, `>>`
  sent to `self`, then `& 1`, no block and no handler
  (`integer_bit_aref_body?`);
- `Integer#>>` and `Integer#&` are mruby's native methods
  (`builtin_class_send_safe?`).

`BC2CPP_INTEGER_BIT_AREF=0` turns the arm off.

## What the arm computes

The arm runs only for a Fixnum receiver and a Fixnum index `i >= 0`. It then
computes `(x >> i) & 1` the way `mrb_num_shift` does: a width of
`MRB_INT_BIT - 1` or more gives the sign (`-1` or `0`), so the bit is 1 for a
negative receiver. Any other case runs the code the site had before. That
covers a bignum receiver, a negative index (`>>` becomes `<<`), a bignum or
Float index, and every non-Integer receiver.

The arm sits in two places:

- In the shared `bc2cpp_getidx` inline helper, after its exact-Array test.
  An Array site therefore costs the same as before. Any other receiver checks
  the Fixnum tags before calling `bc2cpp_getidx_slow`.
- At the site itself, when NumericFlow proves the receiver is an Integer. The
  arm then comes before the generic tests.

The `POLY_SMALL_N` chain behind the arm makes the same assumption. It calls
the compiled `Integer#[]` body for any receiver whose class is `Integer`.

## Checks

`scripts/bc2cpp/integer_bit_aref_check.rb` checks the generated code:

- the helper arm and the proven-receiver site arm are present;
- each refused world (a different body, a program `Integer#>>`, a prepended
  module, the env switch) emits no arm.

It also compares interpreted and compiled runs. The cases cover:

- positive, negative and wide Fixnum receivers;
- indices 0 to 64, `2**40`, negative, bignum, Float and String indices;
- Array, Hash, String and program-class receivers.

A bignum receiver is left out of the comparison. The compiled shim's own `>>`
on a bignum fails with or without this arm, and the arm never handles a bignum.
