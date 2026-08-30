- **An RPG2003 enemy flagged "airborne" (`levitate`) now bobs on the battle
  screen; a genuine RPG2000 database never does, matching real RPG_RT.** The
  monster schema's `levitate` field (LCF enemy field 28) was parsed but read
  nowhere in `mruby-rpg2k`, so every enemy always drew at its plain centred
  position. Confirmed against a reference implementation's own
  flying-offset code, not independently confirmed against genuine RPG_RT
  under wine: the flag is cosmetically inert in RPG2000
  ("2k does not support flying, albeit mentioned in the help file", per that
  source's own comment) and only draws a +/-4px, 256-frame-period sine bob under RPG2003.
  Implemented with a new `Game::Enemy#levitate` reader, `Scene::Map
  #flying_offset`/`#battler_y` (gated on `@state.party.rpg2003?` and the
  member's own flag), and a per-fight `@battle_ui[:frame]` counter ticked by
  a new `#update_enemy_positions` alongside the existing per-frame flash
  decay. Covered by two new `scripts/rpg2k_scene_check.rb` checks, confirmed
  to fail against the pre-fix code before the fix.
