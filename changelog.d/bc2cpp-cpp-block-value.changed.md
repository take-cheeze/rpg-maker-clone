- **Performance:** The bc2cpp compiled code now passes a block that a
  compiled callee only calls as a `Bc2cppBlock`, a C++ value built in the
  caller's frame with no allocation (it was three `calloc`s per call), and
  a nested block that yields to the method's own block is passed the same way,
  so `def each; @a.each { |x| yield x }; end` no longer allocates a block per
  call. The `RProc` wrapper is made only where the block may be kept.
