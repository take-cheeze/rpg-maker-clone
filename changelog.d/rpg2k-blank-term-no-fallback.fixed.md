- **A blank database term now draws blank, not a hardcoded English word.**
  Every menu/battle/shop/inn label sourced from the 用語 (Term) table --
  command rows, HP/MP/Lv/EXP abbreviations, Yes/No, Victory/Defeat, shop and
  inn dialogue, and the composed level-up/skill-learned lines -- used to
  substitute a plain English stand-in (`'HP'`, `'Attack'`, `'Yes'`, ...)
  whenever the field was blank, whether that blankness came from a real
  database or a bare test fixture with no term table at all. Confirmed
  against genuine RPG_RT.exe (docs/TODO.md cycle #122: Nepheshel's own
  `battle_save`/`status` terms are the empty string, and RPG_RT still draws
  that Save row, just unlabelled) that this fallback was wrong: RPG_RT never
  substitutes English for a blank term, it draws the blank. `Game::Party#term`
  and `Scene::Base#term` (and every thin wrapper/call site built on them --
  `nonblank`, `party_term`, `fixed_width_term`, `wait_term_for`,
  `skill_command_label`, the level-up/skill-learned message composers, a
  custom battle command's own `name`) now return the raw string, empty
  included, with no fallback parameter at all.
