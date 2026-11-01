- Fix the native-only Fiber CI check on clean builds by explicitly generating
  the library compiler flags needed to link its standalone test executable.
  Give the bytecode-free wrapper its own build directory so parallel CI checks
  cannot overwrite each other's runtime configurations.
