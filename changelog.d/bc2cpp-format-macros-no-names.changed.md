- **bc2cpp:** the printf conversion macros of `inttypes.h` (`PRIx32 "x"` in
  mruby's value.h) no longer count as method names, so the engine's `x`
  accessors (`Game::Character`, `Sprite`, `Window`, `Rect`, ...) stop keeping
  method-table entries. The closed RPG2000 build drops 9 entries.
