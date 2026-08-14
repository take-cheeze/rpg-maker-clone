- **Battle:** using a switch item (database item type 10) from the battle
  Item command now actually flips its switch. It was already listed as
  battle-usable and consumed from the bag when the action landed, but the
  battle pipeline had nothing to compute for it (no HP/MP/state effect), so
  it silently did nothing every time — and reported "no effect" in the
  battle log on top of it. It now skips ally targeting entirely (a switch
  item has no target, matching the field menu) and flips the switch at the
  same moment the item is consumed. Covered by a new check in
  `scripts/rpg2k_scene_check.rb`.
