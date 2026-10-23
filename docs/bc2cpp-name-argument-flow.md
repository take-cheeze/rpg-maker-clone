# Method-name argument flow

ClosedWorld resolves ordinary positional Symbol arguments with shared bytecode
IR reaching definitions, including MOVE aliases, branch joins, loops and
exception-handler edges. Every possible reaching definition must supply a known
name; an entry value, a call result, a closure write or a refused query keeps the
existing conservative global refusal.

Visibility sends (`private`, `protected`, `public`, `module_function` and related
operations) record the union of possible argument names. The Symbol returned by
`DEF`, `TDEF` or `SDEF` also works, including `private def hidden; end`. An
unrelated method keeps its visibility proof. Ordinary positional arguments to
method installers use the same Symbol flow.

`remove_method` and `undef_method` record every possible removed name. For
`send`, `__send__` and `public_send`, the first argument has its own name set:
any remover alternative causes the remaining arguments' names to be recorded;
any forwarding or unknown alternative refuses removal proofs globally. This
avoids mixing operation names with method-name arguments at joins.

Strings are mutable. Removal accepts a String literal only when its reaching
load is in the adjacent argument-load sequence, with a strictly linear corridor into the call and no intervening effects,
leaving no opportunity for an alias or call to mutate it. String locals, including joins of String literals,
remain unknown. Packed/splat arrays retain the existing adjacent literal-Symbol
recognizer; following their aliases requires a separate mutation and escape
proof.

Run the binary fixture regression check with:

```sh
MRBC=path/to/mrbc ruby scripts/bc2cpp/name_argument_flow_check.rb
```

The fixtures check both effects and retained proofs for unrelated names, plus
unknown inputs, handler joins, closure writes and String mutation refusals.
