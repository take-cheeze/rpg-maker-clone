# Proven Integer native conversions

Closed-world bc2cpp can call `Integer#to_s` and `Integer#to_i` directly when
NumericFlow proves the receiver is an Integer and the call has zero arguments.
The proof covers fixnums and bigints, including values beyond a target's
`mrb_int` range. Decimal conversion uses the public `mrb_integer_to_str` API;
identity conversion retains the receiver.

The registered C bodies, argument specs, public API declaration and method
lookup are checked before admission. Overrides, uncertain lookup, singleton
makers, open worlds, mixed Integer/Float facts, unknown receivers, nonzero
arities and blocks retain the previous dispatch paths.

`BC2CPP_NUMERIC_NATIVE_DIRECT=0` disables the numeric proof route. The focused
runtime parity check is `scripts/bc2cpp_numeric_native_direct_check.rb`, and
`scripts/bc2cpp_numeric_native_direct_mutation_check.rb` checks nine proof
mutants and their control. See [ADR 0357](adr/0357-bc2cpp-numeric-native-conversions.md).

The width shards also run the parity fixture on 32-bit `mrb_int` and no-bigint
libraries using `NN_WIDTH_SAFE=1`; `NN_NO_BIGINT=1` selects matching C++ defines.

On the measured Wio world, cached calls decrease from 2,785 to 2,784, removing
one `to_s` fallback. POLY stays 911. These are static site counts.
