- Corrected stale `Not implemented` notes in `docs/TODO.md`: the
  `CalcSkillToHit` physical formula (now `Game::Party#skill_to_hit` at
  `mruby-rpg2k/mrblib/game.rb:4738`) and RPG2003 cursed-armor permanent
  states (now `Game::Actor#permanent_states` at `game.rb:1842`) are both
  already implemented; each now points to its later ✅ closure.
