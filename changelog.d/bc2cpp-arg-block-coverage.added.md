- **bc2cpp**: register 102 newly-compilable methods unlocked by
  optional/keyword/rest-argument and `#times`-block support (docs/adr/0147
  through 0150) -- 87 in `mruby-rpg2k-compiled` (`Shop#buy`/`#sell`, 5
  `Game::Actor`, 9 `Game::Battle`, 6 `#initialize`s, 3 `Transition`, 2
  `Screen`, `Picture`/`Weather`/`Vehicle` `#initialize`, 3 `Timer`,
  `State#timer`, 2 `Interpreter`, 2 `RPG2k::Window`, 2 `RPG2k`, 4
  `Scene::Base`, 2 `Scene::Battle`, 10 `Game::Party`, 6 `.singleton`
  additions, `TextReveal#advance`, `ChipsetLayout.singleton#quads`,
  `Backdrop.singleton#name_for`, 2 `SaveLoad`, `StatusMenu#draw_value_row`,
  and 20 `Scene::Map`), 14 in `mruby-rgss-compiled` (`Tee#respond_to_missing?`,
  `Window#initialize`, 3 `Graphics.singleton`, `ErrorReport.singleton#log_tail`,
  3 `RGSS.singleton`, 5 `Audio.singleton`), and
  `LCF::Array1D#method_missing` -- plus surgical companion-statement
  argument-list shrinking in `strip_wio_bc2cpp_stubs.rb` (mixed
  stripped/kept `public :a, :b` lists now shrink to the kept names
  instead of raising) and a `:SYM`-node Symbol-arg case (CRuby 3.4).
  Verified zero-gap against `wio_registered_methods.rb` ground truth.
