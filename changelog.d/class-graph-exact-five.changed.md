- **bc2cpp** (class graph facts): `tools/bc2cpp/class_world.rb` now counts a computed constant that `PureEval` folds as
  static, and models `RuntimeError` as a core superclass. Of the 174 classes and modules, 172 are exact (was 168 of 173),
  and the two still unknown are `LCF` and `LCF::Schema` (INT32 constants outside 32 bits, and lambda-valued tables).
  New `scripts/bc2cpp/class_world_check.rb` checks these rules.
