- **RPG2000/2003 battles:** A defending (or 強力防御/strong-defence) target
  can now take genuine 0 damage from a weak enough hit, matching RPG_RT's
  `AdjustDamageForDefend`, which is a bare halving with no floor. Previously
  the halving was floored at a minimum of 1 — a low-ATK attacker's hit
  against a high-DEF guarding target chipped through for 1 HP where real
  RPG_RT deals none — for both a basic attack and an enemy's self-destruct.
  Covered by two new `scripts/rpg2k_logic_check.rb` checks.
