- **装備固定 (equipment lock) is read.** The player/class row's
  `equipment_fixed` field (a boolean an RPG2003 class can override, mirroring
  `strong_defence` / `double_hand`) was parsed but nothing consulted it, so an
  actor the editor marked "fixed equipment" could still swap gear freely in
  the field. `Game::Actor#equipment_fixed?` reads it; `Scene::EquipMenu`
  refuses to even open the item list for such an actor's slot rather than
  opening it and rejecting a choice, matching a reference implementation's
  own equip-selection handling (not independently confirmed against genuine
  RPG_RT under wine). `Game::Party`'s own bag-swapping methods
  are deliberately left unguarded — RPG_RT's `Game_Actor::ChangeEquipment`
  (used by both the menu's low-level swap and the Change Equipment event
  command) does not check the flag either, so the gate belongs to the menu
  scene alone. Left unbuilt: the state-table `cursed` (呪い) half of the
  equipment-lock check, which also locks equipment while an inflicted state is
  flagged cursed — no state in either test bed carries the flag, so there is
  nothing to measure a real implementation against. Covered by two new checks
  in `scripts/rpg2k_logic_check.rb` and one in `scripts/rpg2k_scene_check.rb`
  (the gate is per-actor: a locked party member's slot stays closed while an
  unlocked one's still opens).
