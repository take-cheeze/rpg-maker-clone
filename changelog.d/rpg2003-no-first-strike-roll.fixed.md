- **RPG2003 maps:** A wandering-monster random encounter no longer rolls
  RPG2000's 1-in-32 first-strike chance on an RPG2003 database, matching
  RPG_RT -- the two mechanics are mutually exclusive (RPG_RT's own
  `if`/`else`), and the roll is now skipped outright rather than merely
  discarded, keeping the seeded RNG stream in step with a genuine RPG2003
  run. Covered by a new `scripts/rpg2k_scene_check.rb` check.
