- **Equipping an item no longer raises max HP/MP from its `max_hp_points`/
  `max_sp_points` fields.** `Game::Actor::EQUIP_BONUS_FIELD` summed those two
  fields live over every equipped slot alongside the four combat stats' own
  `atk_points1`/`def_points1`/`spi_points1`/`agi_points1` equip bonus, but
  `max_hp_points`/`max_sp_points` are not part of that "points1" equip-bonus
  family at all — they are grouped with `atk_points2`/`def_points2`/
  `spi_points2`/`agi_points2`, the six fields a Seed-type item spends on a
  one-time, permanent stat-up when *consumed* (`Actor#seed_boosts`), never
  while merely worn. Ported from a reference implementation, not
  independently confirmed against genuine RPG_RT under wine: its own max
  HP/SP getters have no per-equipment summation anywhere, unlike the four
  combat-stat getters, each of which walks every equipped item's own
  points1
  field — RPG2000's editor has no "+Max HP"/"+Max SP" equip-bonus field for
  weapon/shield/armour/helmet/accessory items at all. Fixed by making
  `EQUIP_BONUS_FIELD[0]`/`[1]` (max HP/MP) `nil`, so `#equip_bonus` returns 0
  for them unconditionally instead of reading an item's field; the four
  combat stats are unchanged.
