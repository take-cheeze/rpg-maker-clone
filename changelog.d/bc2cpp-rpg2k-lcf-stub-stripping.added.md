- **`wio_strip_bc2cpp_stubs` (docs/adr/0144) now also runs for
  `mruby-rpg2k` and `mruby-lcf`**, not just `mruby-rgss` — a wio build with
  `RPGMAKER_BC2CPP=1` now deletes the interpreted-bytecode `def` of every
  real bc2cpp-registered method for 11 `mruby-rpg2k` owners
  (`Game::TextReveal`, `Game::MessageConfig`, `Game::Switches`,
  `Game::Variables`, `Game::NumberInput`, `Game::Actors`, `Game::Rng`,
  `Game::MoveRoute`, `Game::Shop`, `Game::Weather`, `Game::Timer` — 74
  methods) and all 12 `mruby-lcf-compiled` owners (`LCF::File`,
  `LCF::Database`, `LCF::MapTree`, `LCF::MapUnit`, `LCF::SaveData`,
  `LCF::MoveCommand`, `LCF::EventCommand`, `LCF::Tree`, `LCF::Sections`,
  `LCF::Array1D`, `LCF::Array2D`, `StringIO` — 34 methods). Real, measured
  `mrbc -g` reduction of the affected source files alone: `game.rb`
  162,963 → 147,790 bytes (-15,173), `lcf.rb` 16,567 → 13,868 bytes
  (-2,699), `lcf_file.rb` 3,431 → 1,492 bytes (-1,939).
- **`strip_wio_bc2cpp_stubs.rb` now supports stripping a one-line
  `def name; body; end`** (previously refused outright — every owner
  `mruby-rgss` had stripped so far happened to use only multi-line `def`s).
  Safe by construction: a one-liner's whole physical line is only dropped
  once the DEFN node's own `first_column`/`last_column` span is confirmed
  to account for everything on that line, so a hypothetical
  `def a; end; def b; end` sharing one line would still refuse rather than
  silently deleting both. 9 of `mruby-rpg2k`'s 11 new owners hit this shape
  in real, checked-in source (e.g. `Game::Timer#seconds`,
  `Game::Switches#initialize`).
- `Game::ChipSet` (a `mruby-rpg2k-compiled` owner otherwise as simple as
  the 11 above) is deliberately left out of this round: one of its own
  registered methods, `#upper_flags`, is marked private via a class-body
  `private :upper_flags` call rather than a bare `private` keyword —
  stripping the `def` while leaving that companion statement in place
  raises `NameError` the moment `mruby-rpg2k`'s own mrblib loads, strictly
  before `mruby-rpg2k-compiled`'s C++ override installs. Left for a future
  round once `strip_wio_bc2cpp_stubs.rb` can also strip a stripped
  method's own companion `private :name`/`protected :name`/`public :name`
  statement.
