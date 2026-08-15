- **A troop member naming a deleted individual enemy id no longer degrades
  silently** — a database shrink can leave one behind, shown as "?" in the
  editor, distinct from the enemy-*group*/troop id case fixed separately.
  `Game::Enemy#initialize` (`mruby-rpg2k/mrblib/game.rb`) already tolerated a
  missing `enemy` row by degrading to a blank/1-HP model; it now also logs a
  `[RPG2k] Enemy: enemy id <id> not found in the database, degrading to a
  blank placeholder` diagnostic instead of doing so with no trace. The
  degrade behaviour itself is unchanged — this is diagnostics only. Covered
  by a new `scripts/rpg2k_logic_check.rb` check.
