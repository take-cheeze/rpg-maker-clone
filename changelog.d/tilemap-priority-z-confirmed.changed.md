- **ADR 0022's tilemap priority `z` formula is confirmed rather than proposed.**
  It was written with "the exact constant to be confirmed against the testbed
  `Spriteset_Map` character-`z` formula". RMXP's own `Game_Character#screen_z`,
  read out of the test bed's `Scripts.rxdata`, settles it: a character's `z` *is*
  its on-screen pixel y, and a tile adds `priorities[tile_id] * 32` — so a
  priority-`n` tile sorts as though it stood `n` rows lower, which is the
  `(ty + prio) * 32 + 32 - oy` the ADR proposed. The derivation and the
  `@always_on_top` ceiling (999) are recorded in the ADR and beside the interim
  constant in `mruby-rgss/src/lib.cxx`.
