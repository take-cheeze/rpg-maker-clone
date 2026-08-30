- **An enemy's own Attack now plays the enemy-attack system SE**
  (`Scene::Base::DB_SE_FIELD` slot 6, `enemy_attack_se`). The slot was
  already declared for slot-numbering and Change System SFX overrides, but
  nothing ever called `play_system_se(SFX_ENEMY_ATTACK)`. Confirmed against
  a reference implementation's own battle scene, not independently confirmed
  against genuine RPG_RT under wine: its normal-attack algorithm's own
  start-SE lookup returns the enemy-attack SE only
  for an enemy-sourced plain Attack, and it plays that SE
  before the action's own animation/execute steps — once,
  at the very start of the action, before any hit/miss/damage resolves, and
  once per action even when a dual-attack enemy swings twice (a repeat
  re-enters at Execute, not Usage). `Battle#deal_attack` now tags its log
  entry with `attacker_ally`, and `Scene::Map#play_battle_action_se` plays
  the SE first when that attacker is an enemy — never for a skill/item hit
  or an ally's own Attack, and only once even across
  `EnemyAction::BASIC_DUAL_ATTACK`'s two swings. Covered by a new
  `scripts/rpg2k_scene_check.rb` check asserting the SE plays for an enemy
  Attack and not for an ally one.
