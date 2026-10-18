- The bc2cpp declared constant check (TC1011) accepts `X: Array` on a constant assigned `(A + B).freeze` (or `A + B`) when
  both operands prove Array, under the same proof and withholding as the type check. Covered by
  `scripts/bc2cpp/declared_array_sum_check.rb`.
