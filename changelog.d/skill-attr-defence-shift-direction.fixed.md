- **A skill's "attribute defence up/down" (field 45, `affect_attr_defence`)
  shift direction now comes from the skill's own scope, not
  `reverse_state_effect`.** This was previously an explicitly-unconfirmed
  guess ("neither Nepheshel nor mtf-meido-action ships a skill with the flag
  set" to check it against). EasyRPG Player's actual source settles it:
  `Game_BattleAlgorithm::Skill::vExecute` (`src/game_battlealgorithm.cpp`)
  computes `auto shift = IsPositive() ? 1 : -1;` right where it applies
  `affect_attr_defence`, and `IsPositive()` was set a few lines earlier from
  `Algo::SkillTargetsAllies(skill)` (`src/algo.h`) — purely the skill's own
  `scope` field, true for every scope except Scope_enemy(0)/Scope_enemies(1).
  `reverse_state_effect` plays no part in it at all (that flag's own
  state-cure/inflict role is separately gated behind an RPG2003-only check in
  the same function, a wider question left untouched here). Fixed
  `Game::Party#skill_attr_shift` (`mruby-rpg2k/mrblib/game.rb`) to read the
  skill's scope (mirroring `#battle_skill_target`'s own enemy-scope test)
  instead of `reverse_state_effect`: an ally-scoped skill (self/single
  ally/all allies — the "buff" shape) always raises resistance, an
  enemy-scoped one (single/all enemies — the "curse" shape) always lowers
  it. Covered by two new `scripts/rpg2k_logic_check.rb` checks (direction is
  scope-driven with `reverse_state_effect` proven inert on both sides; the
  existing shift-and-cap mechanic check reworked around scope-based
  skills), confirmed to fail against the pre-fix code before the fix.
