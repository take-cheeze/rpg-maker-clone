- **bc2cpp**'s `bc2cpp_ary_collect` (`map` on an exact Array) now checks
  whether the block is compiled once per call instead of once per element. It
  also stores each result before cutting the GC arena back, so the arena no
  longer grows by one slot per element. This cuts optcarrot's startup by about
  0.18G instructions (2.41G to 2.22G). See `docs/bc2cpp-collect-direct.md`.
