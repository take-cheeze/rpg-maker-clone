- **RPG2000/2003 maps:** Boarding or landing the airship now snaps the hero
  to face left, matching RPG_RT's own `SetFacing(Left)` at both transitions
  (which bypasses Direction Fix entirely). Previously the hero kept
  whatever direction they were last facing through the whole flight and
  after landing. Boat and ship boarding are unaffected — RPG_RT has no
  equivalent facing change for them. Covered by two new
  `scripts/rpg2k_scene_check.rb` checks.
