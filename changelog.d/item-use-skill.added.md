- **A weapon/shield/armour/helmet/accessory item flagged `use_skill`** is now
  usable directly from the field and battle Item menus, invoking its
  `skill_id` skill for free without being equipped -- the same "item triggers
  a skill" path a type-9 special item already gets, restricted to the classes
  in its `class_set` list when one is set. Covered by new checks in
  `scripts/rpg2k_logic_check.rb`.
