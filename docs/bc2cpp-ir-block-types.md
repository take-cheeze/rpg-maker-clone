# Generic iterator block feedback

For nominal Array element contracts, feedback substitutes the element bound
into literal blocks passed to `each`, `map`, `collect` and `each_with_index`.
The latter also binds its second parameter to Integer. Block bodies use the
shared IR reaching-definition queries to report returns, call receivers and
ivar stores. A block returning its argument retains the originating element
contract; a block returning an integer literal has an independent Integer fact.

The JSON feedback includes `block_argument`, `block_return`, `block_receiver`,
`block_ivar_store`, `iterator_result`, `callback_result` and `block_contract`
rows. For example:

```ruby
# values has the RBS bound Array[String | nil]
values.map { |value| value } # conditional Array[String | nil]
values.collect { |value| 1 } # conditional Array[Integer]
```

The iterator result applies the nominal API contract
`Array[T]#map { |T| U } -> Array[U]`; it is marked declared, including when
the block's result is independently known. These rows describe conditional
iterator contracts, not proofs of built-in method identity. They never seed
optimizer dispatch or enclosing method return inference, and are not yet
exported as enclosing RBS method returns.

Only literal blocks with matching required positional arity are modelled.
Rest/destructured arguments and opaque block calls remain unknown. Breaks,
nonlocal returns and handlers
prevent publishing the normal iterator result. Each result requires all block
return facts to be known. `BC2CPP_IR_BLOCK_TYPES=0` disables these rows.

Custom Ruby methods can also supply yield argument facts. Each receiver must
resolve to a stable exact target whose bounded body uses scalar loads, moves,
control flow and local direct yields. Every yield must have matching arity and
known arguments; multiple sites form a union. Calls, stores, escaping callbacks,
handlers and nested bodies refuse the protocol. The analysis caps bodies at
256 instructions and receiver sets at eight. Independently proved arguments
remain inferred; caller contract bounds retain their declaration provenance.
`BC2CPP_IR_YIELD_TYPES=0` disables this bridge.

Immediate outer captures use parent facts at the invocation point. The block
and transport corridor must be free of opaque effects, capture writes, nested
closures and nonlocal exits. A synchronous nonescaping protocol is required;
an arbitrary RBS callback signature or nominal iterator contract alone cannot
prove this. The current invocation proof comes from the custom-yield summary;
native/core iterators need an independent effect audit before enabling captures.
Captured RBS
bounds remain declared and cannot become independent queries.
`BC2CPP_IR_BLOCK_CAPTURES=0` disables capture facts.

Concrete and method-generic RBS callbacks are retained, for example:

```rbs
def transform: [T, U] (Array[T] values) { (T) -> U } -> Array[U]
```

Known caller value and element bounds instantiate T; a complete block return
instantiates U. `callback_result` reports the substituted conditional result.
Independent block returns and yielded arguments can be checked against callback
contracts; disjoint results produce TC1007, mixed compatible/incompatible unions
produce TC1008, and missing subtype relations remain unknown. Unresolved,
bounded/defaulted variables, class-level generics and optional/rest/keyword
callback shapes are refused. These callback results remain reporting-only and
are not exported into enclosing RBS method returns.
`BC2CPP_IR_RBS_BLOCK_TYPES=0` disables callback contract binding.

See [ADR 0448](adr/0448-bc2cpp-generic-block-feedback.md) and
[ADR 0449](adr/0449-bc2cpp-block-protocols.md).
