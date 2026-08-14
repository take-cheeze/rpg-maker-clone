- **A state flagged "Avoid Attacks" (RPG2003, field 36) now makes its target
  dodge every basic attack unconditionally**, instead of doing nothing at
  all. The `situation` (state) schema's `avoid_attacks` field was parsed but
  read nowhere in `mruby-rpg2k`, so a status built for exactly this purpose —
  RPG2000's closest thing to a guaranteed-dodge "Blink" — never took effect.
  Confirmed against EasyRPG Player's C++ source
  (`Game_Battler::EvadesAllPhysicalAttacks`, `Algo::CalcNormalAttackToHit`):
  a normal attack against such a target always misses, checked first, ahead
  of even a `Restriction_do_nothing` target's own "always hits" rule and a
  必中 (evasion-ignoring) attacker's own bypass. Implemented with a new
  `Game::Battle#evades_all_physical?` and an early `#to_hit` return. Covered
  by a new `scripts/rpg2k_logic_check.rb` check, confirmed to fail against
  the pre-fix code before the fix.
