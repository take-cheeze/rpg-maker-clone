- **LCF: `Array1D`'s field-name lookup table now builds lazily, not on
  every construction.** The previous fix (shared per record type instead
  of rebuilt per instance) still built the table unconditionally in
  `initialize` -- missing every write-only call site, of which
  `Game::State#to_lsd` (`mruby-rpg2k/mrblib/game.rb`, the Save command's
  serializer) has about 18, each also constructing a fresh, throwaway
  schema wrapper Hash per call rather than the shared module constant, so
  the earlier fix's sharing could never apply there either. `sym2idx` now
  builds only on first symbolic field access (`method_missing`), which a
  write-only caller (`e[12] = x`, never `e.some_field`) never triggers at
  all -- read-heavy call sites still get the same per-schema sharing as
  before.
