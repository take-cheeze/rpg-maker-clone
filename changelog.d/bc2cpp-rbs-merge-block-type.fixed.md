- **bc2cpp signatures: a second declaration without a block keeps the first
  one's block type.** Merging two declarations of one method filled untyped
  parameters and returns from the earlier one but always took the later
  block type, so `def each: () -> Integer` erased `def each: () { (Integer,
  LCF::Array1D) -> void } -> untyped`. `Game::Actors#each` and
  `LCF::Array2D#each` lost their declared block parameters this way, and
  `RBS_BLOCK_PARAM_HINT` never saw them. With the block type kept, the block
  in `Game::State#to_lsd` that walks `@party.roster` types its parameter as
  `Game::Actor` and drops its other class arms.
