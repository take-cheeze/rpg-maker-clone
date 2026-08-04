- RPG Maker 2000 main menu: the **Equip** command now opens a working equipment
  screen (`Scene::EquipMenu`) instead of reporting "not implemented". It shows one
  party member's five equipment slots (weapon / shield / armour / helmet /
  accessory) with the item worn in each, plus that member's stats; LEFT/RIGHT
  cycle through the party. Choosing a slot lists the bag's items that fit it (by
  database item type) with a leading Remove entry; choosing one equips it —
  taking it from the bag and returning the previously-worn item to the bag — or
  empties the slot, recomputing the member's stats either way. The bag-aware
  logic is `Game::Party#equip_candidates` / `equip_from_bag` / `unequip_to_bag`
  (distinct from the Change Equipment event command, which does not touch the
  bag), covered by four new checks in `scripts/rpg2k_logic_check.rb` (the CI-run
  host harness); `Scene::EquipMenu` is the RGSS UI over it. Two-handed weapons and
  dual-wield equipping are later refinements.
