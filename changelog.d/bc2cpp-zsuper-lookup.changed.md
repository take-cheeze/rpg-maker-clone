- **bc2cpp compiles a bare `super` into a C method, and drops the
  `ZSUPER_NATIVE_TARGETS` table.** A bare `super` (ARGARY + `SUPER n=*`) that no
  direct rule calls is looked up from the superclass at run time and called
  with the arguments `OP_ARGARY` packs, a rest Array's elements spliced in. A
  method some caller may hand a block keeps its bytecode. The table and its
  hand-written replacements for `respond_to_missing?` and `method_missing` named
  four LCF methods that no longer exist.
