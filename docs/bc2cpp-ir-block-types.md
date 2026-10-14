# Generic iterator block feedback

For nominal Array element contracts, feedback substitutes the element bound
into literal blocks passed to `each`, `map`, `collect` and `each_with_index`.
The latter also binds its second parameter to Integer. Block bodies use the
shared IR reaching-definition queries to report returns, call receivers and
ivar stores. A block returning its argument retains the originating element
contract; a block returning an integer literal has an independent Integer fact.

The JSON feedback includes `block_argument`, `block_return`, `block_receiver`,
`block_ivar_store` and `iterator_result` rows. For example:

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
Captured outer variables, custom yield protocols, rest/destructured arguments
and opaque block calls remain unknown. Breaks, nonlocal returns and handlers
prevent publishing the normal iterator result. Each result requires all block
return facts to be known. `BC2CPP_IR_BLOCK_TYPES=0` disables these rows.

See [ADR 0448](adr/0448-bc2cpp-generic-block-feedback.md).
