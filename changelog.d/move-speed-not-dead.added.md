- **Move Speed is no longer dead code.** `Character#move_speed` (the event-page
  Move Speed field and the `SPEED_UP`/`SPEED_DOWN` move-route commands) now
  drives the per-frame slide: the advance is `1 << move_speed` quarter-tile
  units/frame (a subpixel `slide_frac` accumulator carries the remainder),
  so frames-per-tile is 32/16/8/4/2/1 for RPG2000 speeds 1..6. Jumps use a
  separate table and walk-animation cadence is now speed-dependent too. The
  default (`move_speed` 3) collapses to the previous 8 frames/tile, so the
  baseline pace is unchanged and the existing test suite is not re-baselined.
  Covered by a new `scripts/rpg2k_scene_check.rb` check.
