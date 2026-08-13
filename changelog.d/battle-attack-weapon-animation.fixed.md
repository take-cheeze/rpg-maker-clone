- **A plain battle Attack now plays its own animation.** RPG2000 keeps the
  animation for a basic attack on the *equipped weapon* (item field 20,
  the weapon editor's own "アニメーション" picker) or, unarmed, on the actor
  row's own `unarmed_animation` (field 56, 素手戦闘アニメID) — both decoded by
  the schema and read by nothing, so every Skill/Item animation played
  (see the "Battle animations" entry in `docs/TODO.md`) while a plain sword
  swing stayed silent. `Game::Actor#attack_animation_id`
  (`mruby-rpg2k/mrblib/game.rb`) resolves the primary weapon slot's
  `animation_id` when one is worn and set, falling back to the actor's own
  unarmed id otherwise; `Game::Battle#deal_attack` attaches it (and the
  target's `@enemies` index, needed to centre the animation on the right
  sprite and previously never carried by a plain-attack log entry either)
  onto every entry it returns, hit or miss alike — a miss still swings, only
  the damage is zeroed. `Scene::Map#battle_animation_id` now falls back to
  that field once neither a skill nor an item claims the entry. A monster's
  own basic attack still plays nothing, matching RPG2000: there is no
  equivalent per-enemy field to read (Combatant#actor is nil for an enemy
  snapshot). Covered by new `scripts/rpg2k_logic_check.rb` checks (the
  weapon/unarmed fallback logic itself; a plain attack's log entry carrying
  the resolved animation id and target index; both of a 二刀流 weapon's
  swings carrying the identical id; an enemy attacker carrying none) and new
  `scripts/rpg2k_scene_check.rb` checks (a plain attack with a resolved id
  plays over the targeted enemy sprite the same way a skill/item does; one
  with nothing resolved plays nothing), all confirmed to fail against the
  pre-fix code before the fix.
