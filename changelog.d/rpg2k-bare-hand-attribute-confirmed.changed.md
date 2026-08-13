- RPG Maker 2000: confirmed two more untriaged `docs/TODO.md` claims already
  hold, no code change needed — bare-hand attacks carry no elemental
  attribute (`Actor#weapon_attributes` only scans the weapon slot, so an
  unarmed actor's scan finds nothing), and a full (0%) elemental resistance
  deals exactly zero damage rather than healing (`Battle#apply_attr_multiplier`
  computes `0 * dmg / 100`, never flipping sign on a matched 0% rate).
