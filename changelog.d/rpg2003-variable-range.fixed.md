- **RPG2003 databases now widen a variable's clamp to ±9999999**, instead of
  always applying RPG2000's narrower ±999999. `Game::Variables::MAX`/`MIN`
  clamped every database identically, even though `LCF.var_max`/`var_min`
  (this codebase's own schema-side source for the figure) already branch on
  `MODE == 2003`. Fixed by giving `Game::Variables#initialize` an `rpg2003`
  flag — a new `RPG2003_MAX`/`MIN = ±9_999_999` pair, picked at construction
  instead of the fixed bound — that `Game::State#initialize` reads once from
  the party's own database via `Game::Party#rpg2003?`
  (`LCF::Schema::Database#rpg2003?`'s Classes-chunk-presence check, the same
  per-loaded-database signal `Scene::Menu#build_commands` already keys its
  RPG2003 command list off of) to build its `Variables` object. A save's own
  stored variable values still round-trip unaffected; only the live
  Control-Variables write-path clamp changes. Covered by a new
  `scripts/rpg2k_logic_check.rb` check, confirmed to fail against the
  pre-fix code before the fix.
