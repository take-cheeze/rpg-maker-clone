- **bc2cpp:** the tagged Fixnum `+`, `-` and `*` helpers now set the tag bit
  of their result with `| 1`, so the compiler folds the write-barrier
  immediate test after an `@ivar += n` store (FIXNUM_TAG_BIT, see
  `docs/bc2cpp-tagged-fixnum.md`). optcarrot: about −175K conditional
  branches and −146K instructions per frame.
