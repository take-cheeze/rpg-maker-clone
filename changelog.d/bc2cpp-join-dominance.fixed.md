- **bc2cpp** no longer trusts the textually nearest writer of a register across a
  join. `x = h[k] || Foo.new; x.bar` and `x = Baz.new; x = Foo.new if c; x.bar`
  called `Foo#bar` with no guard, `(h[k] || []).each` was inlined as an Array
  walk that raised for any other receiver, and `@x = h[k] || 0` became a Fixnum
  slot that raised `TypeError` for a Float. Every backward walk feeding an
  unguarded consumer now proves the write dominates the read or joins all
  reaching definitions (ADR 0261, `scripts/bc2cpp_join_dominance_check.rb`).
