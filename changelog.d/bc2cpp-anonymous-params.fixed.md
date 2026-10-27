- **bc2cpp:** a method with an anonymous rest parameter (`def inject(*)`,
  `def f(x, *)`, `def g(*) = h(*)`) no longer generates C++ that does not
  compile (`mrb_value r1 = *;`). mrbc names anonymous parameters by their
  sigil; bc2cpp now gives them a generated name. Covered by
  `scripts/bc2cpp/anonymous_params_check.rb`, which also runs anonymous `**`,
  `&` and `...`.
