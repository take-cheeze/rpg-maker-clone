- Applied the 26 real `# bc2cpp: (...)` argument-type annotations
  `tools/bc2cpp/profile_annotations.rb` confidently resolved from real
  observed evidence to the actual game source: `Game::Actor#initialize`,
  `Game::Map#initialize`, `Game::Transition#initialize`,
  `Game::State#initialize`, `Game::Screen#tint_to`/`#restore_tint`/
  `#shake`/`#flash`, `Game::Interpreter#start_at`,
  `RPG2k::Scene::Map::LRUBitmapCache#initialize`,
  `RPG2k::Scene::ItemMenu#prompt_item_target`, `LCF::EventCommand#initialize`,
  `LCF::MoveCommand#initialize`. Real, measured payoff in `bc2cpp`'s own
  whole-program ivar-embedding analysis: 158 -> 174 embeddable ivars (16
  new), several unlocked as a side effect on ivars not directly annotated
  at all. None of the annotated classes are in either shipped compiled
  gem's own target set yet, so this has no live effect on what ships
  today -- verified both already-shipped targets' own output is otherwise
  unaffected (byte-identical for `LCF::File`-family; `Game::Picture`'s own
  output differs only in a disassembly-echo comment's line number, a
  real but inert side effect of adding real comment lines to the same
  source file, mechanically confirmed to be the *only* difference). See
  `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`'s own follow-up, which
  also documents a real bash `**`-glob gap this found in some of this
  session's own earlier ad hoc verification commands (never in the real
  `mrbgem.rake` build itself, which was always correct).
