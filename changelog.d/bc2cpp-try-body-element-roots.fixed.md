- bc2cpp roots the element reads in a rescue's `begin` body, a block compiled
  as its own function and an inlined loop body. They had no GC root, so an
  element a by-name call removed from its container could be freed while the
  compiled code still used it.
