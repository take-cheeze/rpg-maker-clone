- **bc2cpp: `a, b = pair(x)` now proves the classes of each destructured position.** When every definition of a
  method ends in a literal `[e0, e1, ...]` of one length, NumericFlow carries a class set per position (numbers and
  nil) to the `AREF`s straight after the call, so guarded arithmetic on `a` or `b` loses its by-name else arm when
  the position is proven Integer/Float. In the wio closed world this removes 41 `bc2cpp_slow_*` helper calls from
  the engine (`Game::Transition` split ops, `Scene::Map#update_screen_overlay`); the generated code is
  byte-identical with `BC2CPP_TUPLE_RETURNS=0`. `BC2CPP_NUMERIC_ROOTS=<file>` writes the leaves behind every
  still-unproven operand. Covered by `scripts/bc2cpp_tuple_return_check.rb` and its mutation check
  (`docs/adr/0311-bc2cpp-tuple-return-facts.md`).
