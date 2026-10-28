- **bc2cpp drops the hand-kept `SUPER_TARGETS` list.** Whether a `super` call
  may run with no block is now decided only by the whole-program check that no
  caller passes the method a block (`SUPER_NO_CALLER_BLOCK`), which already
  covered every listed method. All 21 former entries still compile.
