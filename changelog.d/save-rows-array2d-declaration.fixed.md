- The bc2cpp-compiled builds load saves again and no longer raise
  `BC2cppDeclarationViolation` on three false declarations: a save's picture,
  actor, target, common-event, map-event or event-stack table is an
  `LCF::Array2D` (not an `Array`), `LCF::File#[]` takes a chunk id as well as a
  section name, and `Game::Character#face` returns nil when the facing is locked.
