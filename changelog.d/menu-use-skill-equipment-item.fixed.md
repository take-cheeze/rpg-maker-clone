- **Menu scene:** a `use_skill` equipment item (weapon/shield/armour/helmet/
  accessory, schema field 71) is now special-cased in the field Item menu the
  way a type-9 special item already is — a self/all-ally-scope skill casts from
  the party leader with no target prompt and an Escape/Teleport skill warps
  straight away, instead of always asking for a target. The warp helpers
  `Game::Party#use_special_escape_item` / `#use_special_teleport_item` now also
  accept `use_skill` equipment items (the cast is free and the item, like every
  equipment type, is not consumed). Covered by new
  `scripts/rpg2k_scene_check.rb` and `scripts/rpg2k_logic_check.rb` checks.
