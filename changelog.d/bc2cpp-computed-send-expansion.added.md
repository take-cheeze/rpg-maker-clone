- **bc2cpp** expands a computed-name `__send__` whose name is provably one of a
  finite Symbol set (a frozen constant Array/Hash of Symbols, or a `case`/`?:` over Symbol literals) into
  direct per-name arms, with the by-name send kept only as a logged proof-violation arm (ADR 0303).
  `BC2CPP_COMPUTED_SEND=0` turns it off. optcarrot's `r_op`/`w_op` sends name method parameters and are
  not covered; the ADR says what proof they would need.
