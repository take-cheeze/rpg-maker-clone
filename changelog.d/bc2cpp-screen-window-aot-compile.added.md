- The opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler now also covers 39 of
  `Game::Screen`'s own 43 real bytecode methods (screen tint/shake/flash/
  pan/fade effects) and 32 of `RPG2k::Window`'s own 35 (the RPG2000-style
  UI window), both added to `mruby-rpg2k-compiled` alongside
  `Game::Picture`/`Game::EnemyAction`. Needed four new opcodes in
  `tools/bc2cpp/bc2cpp.rb`: `LOADSELF` (`self.foo = ...`), `MUL`, and
  `ARRAY`/`AREF` (literal arrays and the destructuring multiple-assignment
  they enable, e.g. `x, y, w, h = some_call(...)`). `Game::Screen` is the
  first shipped target whose own `#initialize` compiles clean, so it's
  also the first to get real ivar embedding (21 provably-Fixnum ivars on
  a new `Game__Screen_ivars` RData struct) rather than staying on the
  ordinary dynamic ivar table. See
  `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`.
