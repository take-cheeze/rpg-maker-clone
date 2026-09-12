- **wio's `RPGMAKER_BC2CPP` build now also strips the interpreted-bytecode
  body of `Game::Interpreter`'s own bc2cpp-covered methods** (docs/adr/0144),
  the RPG2000/2003 event-command interpreter — the smallest of the three
  remaining `DIRECT_CONSTRUCT_TARGETS`/`NATIVE_ARG_TARGETS`-touching owners
  rounds 38-40 left deferred (`RPG2k::Scene::Map`/`RPG2k::Scene::Battle`,
  224/110 methods, still deferred). `Game::Interpreter` has 173 real
  registered methods total (ground truth from a real
  `wio_registered_methods.rb` run, never hand-counted); 169 are defined in
  `mrblib/interpreter.rb` and strip cleanly, the other 4
  (`#take_revealed_monsters`, `#take_fled_monsters`, `#take_monster_kills`,
  `#take_battle_background`) are defined in a second real class reopening in
  `game/battle_support.rb`, already excluded from wio's own `spec.rbfiles`
  by the existing wio-only battle trim, so they strip nothing there — the
  same familiar partial-owner shape `Game::Map`/`Game::State`/`Game::Actor`/
  `Game::Party` already established. One real companion-statement hazard
  found and handled: `#start_death_handler`'s own `public
  :start_death_handler` statement, removed together with its `def` by round
  38's companion-statement-stripping mechanism (unmodified this round),
  verified with a real CRuby `load` of the rewritten source raising no
  `NameError` (and, as a sanity check on the check itself, a hand-built
  def-only-removed fixture was confirmed to reproduce the exact `NameError`
  this mechanism exists to prevent). A neighboring `public
  :start_random_battle` statement names an unregistered method and is left
  completely untouched. 6 of `Game::Interpreter`'s own registered methods
  (`#character_ref`, `#trunc_div`, `#trunc_mod`, `#find_choice_option`,
  `#vehicle_operand`, `#screen_operand`) are also `NATIVE_ARG_TARGETS`
  entries in `tools/bc2cpp/bc2cpp.rb` (using the native `mrb_int` calling
  convention rather than `mrb_value`) — confirmed empirically, not just
  assumed to carry over from round 38's `Game::Actor`/`Game::Screen`
  precedent, that stripping their interpreted bodies is unaffected: all six
  are ordinary multi-line `def`s that strip, parse, and AST-diff clean like
  any other method, since this mechanism only ever rewrites the *base*
  gem's own interpreted-bytecode `mrblib` source and never touches
  bc2cpp.rb's own separate compile of the unstripped original. Real `mrbc
  -g` measurement on `mrblib/interpreter.rb` alone: 78,235 → 22,235 bytes,
  a 56,000-byte (71.6%) reduction. Regression check: every other
  wio-relevant `mrblib` file (`game.rb`, `scene/*.rb`, 14 files total)
  strips byte-for-byte identically to before this round's addition.
