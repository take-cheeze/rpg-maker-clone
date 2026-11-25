- **bc2cpp**: a compiled method with keyword parameters no longer builds the
  keyword Hash that mrbc makes for a bare `super`, unless the method or one
  of its blocks has a bare `super`. 26 of the engine's 29 keyword methods
  skip it, so the map sweep makes 26% fewer Hashes, and the Wio firmware is
  1.3 KB smaller. `BC2CPP_KWARG_NO_HASH=0` turns this off.
