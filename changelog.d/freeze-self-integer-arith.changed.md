- The bc2cpp type check now records that `freeze` returns its receiver: a constant assigned from a literal's `.freeze`
  keeps the literal's class (`inferred:freeze-self`), and an Integer arithmetic constant may be frozen
  (`(A - B).freeze`) and keep its interval. Both need `freeze` stock on the receiver's class. Report-level; covered by
  `scripts/bc2cpp/integer_arith_constant_check.rb`.
