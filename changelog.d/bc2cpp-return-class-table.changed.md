- `tools/bc2cpp/bc2cpp.rb` keeps a return-class table (`codegen_return_classes.rb`): a second run of
  `NumericFlow` whose only sources are literals, a provably fresh `Klass.new` and calls of names whose
  every definition returns the same class, as a fixpoint over recursion, `rescue` paths and block
  `return`s. A receiver that holds one such class on every path (`x = foo(...); x.bar`, `@w = Window.new;
  @w.z = 1`) makes a `TYPED` call a guard-free direct call (`EXACT_TYPED`, which also takes the
  receivers the fresh-`new` proof already covered) and lets the exact-receiver arms of ADR 0280 drop
  their class test. `NumericFlow` also models catch handlers, Range literals and block `return`s, so a
  method with `rescue` has numeric facts. Wio: cached dispatch sites 10,597 to 10,383, `TYPED` arms 492
  to 246. Covered by `scripts/bc2cpp_return_class_check.rb`. See docs/adr/0289.
