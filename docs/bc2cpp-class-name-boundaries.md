# bc2cpp class-name boundaries

IR value classes are Symbols; the prepared RBS lookup indexes use String owner
names. `RbsSignatures.ir_class_name` bridges that boundary with `Symbol#name`,
which supplies the Symbol's frozen String spelling. Callback binding and
explicit-receiver contract lookup reuse that one spelling for the owner chain,
method target and receiver bound.

The existing String lookup keys and cached hierarchy remain unchanged. A String
input keeps its object identity, and non-Symbol inputs keep the previous `to_s`
behavior, including the empty spelling for `nil`. Qualified and non-ASCII class
names preserve their bytes and encoding. This adds no class-name cache or
retention table, and method-name identifiers remain Strings.

## Validation and allocation scope

`explicit_receiver_override_contracts_check.rb` covers Symbol spelling identity,
String identity and the nil fallback alongside its prepared/direct lookup,
subclass, method-removal and core-class cases. Self-call, mixin, callback/block
protocol and context-result checks cover the existing reporting behavior.

A warmed host-Ruby microbenchmark of 100,000 class-name lookups allocated 100,002
objects using `Symbol#to_s` and 1 object using `ir_class_name`, including sampling
overhead. This establishes removal of transient lookup-name allocations; it is
not a measurement of complete-compiler speed or peak memory. An explicit-call and
generic-callback fixture also produced identical full context/type JSON reports
with the new spelling and a baseline helper using `to_s` (9 IR feedback rows).
