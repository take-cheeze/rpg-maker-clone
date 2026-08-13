- **呪われた装備 (cursed equipment) locks its own slot.** The item table's
  `cursed` field (schema.rb:194, alongside the other armour-property flags)
  was parsed but nothing consulted it, so a cursed weapon or armour piece
  could be swapped or removed in the field like any other gear.
  `Game::Actor#slot_cursed?` reads the item currently occupying a slot;
  `Scene::EquipMenu` refuses to even open that slot's item list, the same
  way it already does for `#equipment_fixed?` (an unrelated actor/class
  trait). Same split as that flag: RPG_RT's own `Game_Actor::ChangeEquipment`
  does not consult `cursed` either, so `Game::Party#equip_from_bag` /
  `#unequip_to_bag` stay unguarded — a Change Equipment event command can
  still force a cursed item off, only the menu gates on it. Not part of this:
  the *other* "cursed" flag, on the state table (2003 only, `situation.cursed`
  at schema.rb:403), which also locks equipment per EasyRPG's
  `Game_Actor::IsEquipmentFixed` while an inflicted status carries that flag —
  left unbuilt, same as before, since no state in either test bed carries it.
  Covered by two new checks in `scripts/rpg2k_logic_check.rb` and one in
  `scripts/rpg2k_scene_check.rb` (the gate is per-slot: a cursed weapon locks
  only the weapon slot, an unrelated empty slot still opens).
