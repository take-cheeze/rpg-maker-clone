- **bc2cpp**: a declared `Array[T]` parameter or `@items: Array[T]` ivar no longer raises BC2cppDeclarationViolation on
  a slice such as `xs[0...-1]` or `xs[1..]`. Only an Integer index is checked and typed as an element read; a Range or
  `xs[i, n]` slice reads as an Array whose loop or element read still tests and types `T`. An index the compiler cannot
  classify is tested at run time. `BC2CPP_DECLARED_INDEX_KIND=0` restores the old reading.
