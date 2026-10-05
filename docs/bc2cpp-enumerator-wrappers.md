# Compiled Enumerator wrappers

Closed-world core compilation admits seven Enumerator methods: `inspect`,
`size`, `rewind`, `feed`, `next`, `peek` and `peek_values`.

Their bodies must come from mruby-enumerator and contain no block operations,
lambdas or Fiber references. Each registered entry executes compiled code only
in the root context. Inside a Fiber it executes the saved original bytecode,
including callbacks that yield. Direct dispatch cannot bypass this guard.

The remaining Enumerator methods stay interpreted. Compiled Fiber suspension
and escaping compiled closures are separate work; native Fiber APIs already
execute in C.

Set `BC2CPP_ENUMERATOR_WRAPPERS=0` to disable this admission. Run
`scripts/bc2cpp_enumerator_wrappers_check.rb` with `MRBC` and a full-core mruby
build for generated-code and runtime comparisons. The companion mutation check
verifies seven withdrawn proof conditions and an unchanged control.

See [ADR 0350](adr/0350-bc2cpp-enumerator-wrappers.md).

## Measured world

With the same Wio analysis inputs, enabling wrappers raises compiled entries
from 3,056 to 3,063 and compiled core methods from 183 to 190. Deliberate core
exclusions fall from 29 to 22; three rejected method bodies remain, giving 25
interpreter-only method bodies instead of 32. Guarded methods retain bytecode
for Fiber execution, so this is not the count of all retained bytecode.

Cached dispatch sites rise from 2,772 to 2,785 and POLY sites from 897 to 906:
the newly compiled wrappers expose their delegated sends in the generated code.
These static counts do not establish a runtime speedup.
