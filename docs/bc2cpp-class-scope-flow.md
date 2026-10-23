# Class-body scope flow

`BytecodeIR.class_body_path` resolves the qualified name of a CLASS or MODULE
opener from every definition reaching its outer-scope register. Shared bytecode
IR origin queries follow MOVE aliases, branches, loops and exception-handler
edges, including the value carried into a loop that executes zero times.

A LOADNIL outer uses the caller's lexical namespace; OCLASS names the top-level
Object scope. Every reaching definition must be one of these and produce the
same qualified name. At top level, lexical nil and OCLASS agree. Inside `Outer`,
their paths differ (`Outer::Child` versus `Child`), so the query refuses.
Unknown values, entry values, captured-local writes and exhausted queries also
refuse. A constant-path outer remains the caller's responsibility.

Unique class-name analysis and constructor-pool discovery share this query.
Neither may attribute a class to the textually nearest scope when another path
supplies an unknown or different scope. `class_bodies` retains its structural
requirement that an opener's EXEC be the immediately following instruction on
the same register; empty classes cannot borrow a later class's body.

Run the existing registered validator with:

```sh
MRBC=path/to/mrbc ruby scripts/bc2cpp/class_bodies_check.rb
```

Its binary fixtures cover nested, explicit-root and constant-path scopes and
empty/body association. Explicit CFG cases cover aliases, joins, loops,
handlers, unknown overwrites and captured writes. Those cases make the old
`last_writer` proximity API raise, ensuring scope analysis uses flow queries.
