- The opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler now also covers 7 of
  `Game::Timer`'s own 10 real bytecode methods (the RPG2000 Timer/Timer2
  countdown backing model), all 7 of `Game::Switches`'s own real methods
  (the 1-indexed boolean flag store event pages read from), and 5 of
  `Game::Variables`'s own 6 (the same for integers). All three added to
  `mruby-rpg2k-compiled`, none needing any new opcode work. `Game::Switches`
  is the sixth target (after `Game::Screen`/`Game::Transition`/
  `Game::State`/`Game::Map`/`Game::ChipSet`) whose own ivars get real
  `RData` embedding: `@revision` is provably Fixnum, verified safe the
  same way every prior embedding target was. Adding `Game::Timer` also
  unlocks a real devirtualization synergy in already-shipped
  `Game::State#timer_seconds`/`#timer2_seconds`/`#timer_display_text`,
  which now call directly into `Game::Timer`'s own compiled methods. See
  `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`'s own follow-up.
