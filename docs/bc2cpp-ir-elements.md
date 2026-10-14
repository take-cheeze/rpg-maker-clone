# IR container elements

IR feedback consumes existing exact-class facts for literal index results after
shared reaching definitions succeed. The compiler's fresh, in-bounds literal
array proof retains its alias, mutation and control-flow restrictions.

Declaration-aware IR also reads element bounds from direct `Array[T]` and
`Hash[K, V]` RBS argument and ivar contracts. Every reaching receiver definition
must retain a supported element bound. Array reads require an Integer index or
`GETIDX0`; an unknown or slicing index is refused. Both container reads include
nil for an absent index/key. Nested container bounds retain only the outer
value class, not recursive shapes.

These results carry `element:argument:Rn` or `element:ivar:@name` provenance,
plus any receiver/index contracts. They cannot justify exact dispatch and are
excluded from independent inferred return suggestions. Unsupported or untyped
elements remain unknown. Local assignment loses the declaration's element bound
unless shared definitions still lead to the declared argument or field.

`BC2CPP_IR_ELEMENT_TYPES=0` disables this reporting extension. It does not alter
compiler optimization proofs. See [ADR 0445](adr/0445-bc2cpp-ir-annotation-coverage.md).
