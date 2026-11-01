- Fix the `ambiguous call to bc2cpp_getidx/bc2cpp_setidx` closed-build failure
  after eliminating `[]`/`[]=` from the method tables: the loader's weak
  declarations collided with the strong `static` definitions in the same TU.
  `bc2cpp.rb` now plans the load before emitting the helpers, forces on the
  ones only the load names, and defines `BC2CPP_INDEX_HELPERS_DEFINED` ahead
  of the load code, which skips its own declarations there.
