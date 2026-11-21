- **bc2cpp** closed build: a call on another call's result is dispatched directly more often. An exact
  Array's `reject { }`, `uniq { }`, `sort` and `size` results now have a known class, a resolved method's
  `T?` result keeps its class, and ten engine methods whose results feed chained calls carry
  runtime-checked return declarations (`sig/bc2cpp/declarations.rbs`, `callee_returns.rbs`). Owner calls
  1244 -> 1182. Check `scripts/bc2cpp/declared_def_return_check.rb`.
