# Receiver-relative RBS contracts in bytecode IR

The reporting analysis consumes a single-overload RBS `self` return as a
receiver-relative nominal bound. For example, `(Actor actor)` followed by
`actor.refresh`, with `def refresh: () -> self`, produces an `Actor` bound.
A receiver union substitutes each member separately. This does not assert
object identity or an exact runtime class.

Call contracts follow the recorded runtime method lookup order: prepended
modules, the owner, included modules in reverse inclusion order, then the
superclass. An actual method definition without a usable return contract
stops lookup; it cannot borrow an older ancestor's signature. Unknown mixins
or cyclic ancestor paths refuse the query. RBS `include` declarations alone
do not establish runtime mixin relationships.

These results retain argument and call-contract dependencies. They remain
`declared` facts and are excluded from independent inferred RBS suggestions.
Block calls still refuse normal-return contracts because a breaking block
can replace the callee result. Existing code-generation hint kinds are
unchanged.

Direct `Array[T]` and `Hash[K, V]` declarations additionally retain nominal
element bounds for the reporting analysis. Unsupported element types and
unions containing `untyped` supply no element bound. Nullable containers do
not acquire non-null container metadata. Array indices still require the
separate indexing proof described by the IR analysis.

Optional, rest, trailing and keyword arguments, overload selection,
interfaces, type aliases, and unions involving `self` remain unsupported by
this extension. Optional arguments require modeling their default-value
writes before their contracts can safely seed register reads.
