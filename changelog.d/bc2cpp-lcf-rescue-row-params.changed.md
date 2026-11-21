- **bc2cpp**: LCF database reads inside `rescue`-protected methods (the
  windowskin, title and sound-effect loaders) and row parameters filled from
  another object's method now compile as direct calls, and
  `Game::State.from_lsd` declares its save as `LCF::SaveData`.
