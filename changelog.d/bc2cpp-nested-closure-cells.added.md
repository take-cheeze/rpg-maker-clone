- **bc2cpp**: a block that is kept (stored, returned) and nested in another block can read and write the locals of the
  frames above that block, in methods, Fiber bodies and block steps; its stores gray the cells Array instead of keeping a
  root per slot.
