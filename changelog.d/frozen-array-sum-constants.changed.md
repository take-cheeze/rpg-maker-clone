- The bc2cpp type check now types a constant assigned `(A + B).freeze` (or `A + B`) as `Array` when both operands prove
  Array, as `inferred:array-sum`; `Array#+` is withheld when a Ruby `+` or `freeze` could replace it. Report-only:
  generated code is unchanged.
