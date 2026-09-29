- bc2cpp now proves rescued exception receivers through mruby's two-register
  `RESCUE` instruction, allowing safe direct lowering of `Exception#message`.
