- **Battle hits now play the database's per-hit sound effects.** The System
  table's `enemy_damaged_se`, `actor_damaged_se`, `dodge_se`, `enemy_death_se`
  and `item_se` fields (alongside the already-consumed cursor / decision /
  cancel / buzzer / battle-start / escape slots) were parsed but never played,
  so a fight ran through its damage, dodges, kills and item use in silence.
  `Scene::Map` now fires the matching cue the moment each lands — a hit on
  either side, a miss, a defeated enemy and an item used — reusing the exact
  `play_system_se` / Change System SFX override mechanism the existing system
  sounds already go through, extended with five more slots
  (`Scene::Map::DB_SE_FIELD`) that keep counting through the database's own
  field order so a `Change System SFX` command naming any of them still lands
  on the right one. Independent checks, not a single winner-takes-it: a
  killing blow plays its damage sound and then its death cry, matching
  a reference implementation's battle scene firing separate damage and
  death sound effects rather than one replacing the other — not
  independently confirmed against genuine RPG_RT under wine. Left silent:
  `enemy_attack_se`, RPG_RT's sound for the *start* of an enemy's swing before
  the hit lands — this build's round animation has no separate wind-up moment
  to hang that on (a plain attack is one step: land the hit, then banner and
  pace by it), so the slot is declared (for the numbering and for Change
  System SFX overrides to land correctly) but not yet played, rather than
  played at the wrong moment. Covered by new assertions in three existing
  `scripts/rpg2k_scene_check.rb` checks (a landed hit plays its damage SE, a
  fallen enemy plays its death SE, and a used item plays its own cue).
