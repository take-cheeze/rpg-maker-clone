- **RPG2000/2003 battle log:** A skill invoked by a battle item (a special
  item, or a weapon/shield/armour/helmet/accessory flagged to invoke a
  skill) now opens with the *item's own* "used it!" line when the item
  leaves its `using_message` field at the database default, matching real
  RPG_RT — previously such an item always displayed the skill's own borrowed
  sentence instead, regardless of the item's own flag. An item that
  explicitly sets `using_message` still shows the skill's own sentence, and
  a skill cast from the Skill menu is unaffected either way. Covered by four
  new `scripts/rpg2k_scene_check.rb` checks.
