# Factory analysis on the bytecode IR

The closed-world analysis follows values loaded from `Class`, `Module`, `Struct`
and `Data` through MOVE aliases. `FactoryFlow.uses` reuses
`IrSymbolFlow.value_reads`, which walks normal and exception-handler edges,
retains the old value on a write's handler edges, and stops at overwrites on
normal edges. Uses of every alias are checked, including uses after a native
read or a constructor. A dead load or overwritten alias does not escape.

For example, both bases in this join are recorded as dynamically subclassed:

```ruby
factory = Class
base = condition ? BaseA : BaseB
factory.new(base)
```

Superclass arguments come from shared reaching definitions, following moves
and crossing handler edges. Every reaching writer must load a constant;
unknown values refuse the factory proof. `Class.new` without arguments records
the implicit `Object` superclass. Struct member arguments likewise require
Symbol literals on every reaching path; their possible names and setters are
all recorded as unknown method definitions. Register reuse cannot turn an
unrelated nearby Symbol into a member name.

Comparisons and naming sends retain the existing native-only identity check.
Storing or returning a factory, passing it to an unapproved call, or capturing
an alias in a nested block conservatively sets `class_factory_escape`.
Unresolved flow or an exhausted alias budget also refuses. `Data` construction
remains unsupported. Packed/splatted arguments, keyword constructor calls,
computed member names and mutable String member names conservatively refuse;
no nearest-writer fallback is used. This does not extend the registry's separate
recognition of named Struct layouts.

The existing `scripts/bc2cpp/struct_receiver_check.rb` CI and coverage entry
checks superclass/member joins, multiple constructors, loops, overwrites,
subsequent escapes, handler escapes and budget exhaustion.
`self_new_leaf_check.rb` also checks generated dispatch and interpreted/compiled
runtime parity for construction through an alias with a joined superclass:

```sh
MRBC=/path/to/mrbc ruby scripts/bc2cpp/struct_receiver_check.rb
```
