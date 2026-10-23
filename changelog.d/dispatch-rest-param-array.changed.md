- **bc2cpp**: the dispatch analysis types an entry register that the ENTER spec
  names as the rest parameter as an Array (core). The VM always fills it with an
  Array. The closed gate still fails on `Enumerator#each`'s `dup` of `@args`,
  which needs a declared instance-variable type.
