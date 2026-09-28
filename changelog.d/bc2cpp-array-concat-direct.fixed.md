- bc2cpp now emits an exact-class direct path for one-argument `Array#concat`,
  using mruby's public array conversion and concatenation helpers. Other
  arities and receiver classes retain Ruby dispatch.
