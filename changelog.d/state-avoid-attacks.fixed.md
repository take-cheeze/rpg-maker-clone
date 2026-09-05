- **A state flagged "Avoid Attacks" (RPG2003, field 36) no longer makes its
  target dodge every basic attack unconditionally**, reverting a prior
  revision of this fragment. That revision ported a reference
  implementation's own all-physical-evasion check without independently
  confirming it against genuine RPG_RT, on the theory that a status parsed
  but never read was RPG2000's closest thing to a guaranteed-dodge "Blink".
  Confirmed wrong under wine: a target carrying a freshly-authored
  `avoid_attacks`-flagged state and no other restriction still took a
  steady, ordinary stream of hits from a plain enemy Attack across eight
  full rounds, never once dodging. Genuine RPG_RT does not appear to wire
  the flag into the normal-attack to-hit check at all. Reverted by dropping
  the `Game::Battle#evades_all_physical?` short-circuit from `#to_hit` and
  removing the now-dead method. Covered by rewriting the existing
  `scripts/rpg2k_logic_check.rb` check in place, now asserting the flag is
  inert rather than asserting it forces a flat 0% hit chance.
