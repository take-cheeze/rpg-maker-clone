- The bc2cpp-compiled builds no longer raise `BC2cppDeclarationViolation` when a
  save's picture, actor, target, common-event, map-event or event-stack table is
  read or written: those typed save fields are declared as `LCF::Array2D`, the
  table they actually hold, instead of `Array`.
