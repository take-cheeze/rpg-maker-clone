# Integer bit-operator results

bc2cpp's numeric flow (ADR 0276) tracks, per register, whether a value is an
Integer, a Float, or something else. `NumericFlow::INT` means an Integer class,
fixnum or bignum (ADR 0279).

`CodeGen#numeric_send_on_number` (`tools/bc2cpp/codegen_numeric_returns.rb`) gives
the result class of a send to an Integer or Float receiver:

| Send | Operands | Result |
| --- | --- | --- |
| `&`, `\|`, `^` (one argument) | INT, INT | INT |
| `&`, `\|`, `^` | INT, any other class (Float, nil, other) | OTHER |
| `&`, `\|`, `^` | Float receiver | OTHER |
| `<<`, `>>` | any | OTHER |

An operand that no instruction has written yet yields no value, as `+` and `*`
do. The INT rule is the class claim `+` already makes: `Integer & Integer` is an
Integer, and the codegen's bignum slow paths (`mrb_bint_and` and friends) handle
a bignum result.

`<<` and `>>` stay OTHER because nothing bounds a shift. A negative `>>` count
shifts left.

Kill switch: `BC2CPP_BITOP_RESULTS=0` removes the rule, and the output matches
the build without it. The check is `scripts/bc2cpp/bitop_results_check.rb`: its
host section runs everywhere, and its fixture section (generated code with
MRBC) runs in the nightly `bc2cpp-checks` job. It is also listed in `ruby-checks`
and `scripts/coverage/report.rb`.

The shipped build's output does not change with the rule on. The rule's INT
results reach no `+`, `-` or `*` arm in the shipped build. See ADR 0431 for the
design and the measurement.
