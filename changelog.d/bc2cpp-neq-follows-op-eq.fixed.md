- **bc2cpp `!=` now answers what the interpreter's `!=` answers.**
  `BasicObject#!=` is `!(self == other)` through `OP_EQ`, which compares an
  Integer/Float pair in place even when Ruby reopens `Integer#==`. The
  compiled `!mrb_equal` sent the reopened `==` instead. In a world with
  `class Integer; def ==(o); ...; super; end; end` it said
  `2**62 != 2**62 + 1` was false, because `super` reaches `Comparable#==` and
  the pinned `Integer#<=>` compares those two as doubles. NEQ_OP_EQ follows
  `OP_EQ` arm by arm (`docs/bc2cpp-array-write-inline.md`,
  `scripts/bc2cpp/integer_fast_arms_check.rb`).
