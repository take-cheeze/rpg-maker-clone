- The bc2cpp-compiled builds no longer raise `BC2cppDeclarationViolation` when a
  save's picture, actor, target, common-event, map-event or event-stack table is
  read or written (those fields are declared `LCF::Array2D`, the table they hold,
  instead of `Array`), or when a direction-fixed character is told to face a
  direction (`Game::Character#face` may return nil).
