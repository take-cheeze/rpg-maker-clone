- **A shield/armour/helmet/accessory's 物理回避率アップ (`raise_evasion`, item
  field 26) now lowers a normal attack's chance to land.** 12 of Nepheshel's
  items carry the flag and nothing read it, so a shield bought specifically
  for its dodge bonus was purely a stat stick. `Game::Actor#physical_evasion_up?`
  is true whenever any equipped non-weapon item carries the flag (ported
  from a reference implementation, not independently confirmed against
  genuine RPG_RT under wine), and `Game::Battle#to_hit` subtracts a flat 25 from
  the attacker's already agility-adjusted hit chance against such a target —
  the same place and amount as that reference implementation's own to-hit
  formula. A 必中
  weapon's evasion-skip still returns before this term is ever consulted,
  matching that a wielder's guaranteed hit ignores the target's evasion
  entirely, gear included.
