- **bc2cpp** compiles a block body that forwards its frame's block out of a
  method with an optional argument and a `&block`, and out of a block nested
  inside another block (ADR 0330). `Array#permutation`, `Enumerable#cycle` and
  `File.foreach` now compile, taking the whole program's `#error` markers from
  16 to 8. `BC2CPP_OPT_BLOCK_FRAME=0` restores the previous behaviour.
