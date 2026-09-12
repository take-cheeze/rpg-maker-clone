- **`strip_wio_bc2cpp_stubs.rb` (docs/adr/0144) now also deletes a
  stripped method's own companion `private :name`/`protected :name`/
  `public :name` statement** when every name it lists is itself being
  stripped from the same owner (a mixed stripped/kept argument list, or
  one this script cannot statically read at all, raises rather than
  guesses). This unblocks `Game::ChipSet` — deferred since round 35
  because its own `private :upper_flags` would otherwise raise a real
  `NameError` at mrblib load time once `#upper_flags`'s own `def` is
  stripped. Verified against a real repro: the old stripper's own output
  for this file really does raise exactly that `NameError` under a real
  CRuby `load`; the new stripper's output loads clean. A regression check
  confirmed the new stripper still produces byte-for-byte identical
  output for every one of rounds 35–37's own already-shipped owners.
- **`wio_strip_bc2cpp_stubs` now also covers `Game::ChipSet` (9 methods),
  `Game::Map` (11 of 12), `Game::Transition` (32), `Game::State` (21 of
  23), `Game::Screen` (41), `Game::Actor` (65 of 74), and `Game::Character`
  (14)** — a first, bounded slice of the larger `DIRECT_CONSTRUCT_TARGETS`/
  `NATIVE_ARG_TARGETS`-touching owners round 36/37 left as a standing
  future-round item. `Game::Map`/`Game::Transition` are both
  `DIRECT_CONSTRUCT_TARGETS` members whose own `.new` call sites bypass
  ordinary dispatch for a direct `#initialize` call — checked directly
  against bc2cpp.rb's own registry and confirmed this changes nothing for
  this mechanism, since both classes' own `#initialize` is itself an
  ordinary registered method the same ground truth (`wio_registered_methods.rb`)
  already covers. Each owner got the same full soundness pass as every
  prior round (real registry ground truth, AST-walked companion-statement
  hazard check, whole-closed-world `mrb_funcall` grep, real strip + parse
  + AST-diff verification, real `mrbc -g` measurement). Real, measured
  `mrbc -g` reduction on `game.rb`, isolating each owner's own marginal
  contribution: ChipSet -2,520; Map -1,852; Transition -7,444;
  State -3,796; Screen -7,654; Actor -11,799; Character -2,292 — roughly
  -37,357 bytes combined for this round's own 184 methods. `Game::Party`,
  `Game::Battle`, `Game::Interpreter`, `RPG2k::Scene::Map`, and
  `RPG2k::Scene::Battle` remain deliberately deferred — each large enough
  (72–224 registered methods) to need its own dedicated round rather than
  a rushed pass.
