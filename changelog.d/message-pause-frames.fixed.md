- **A `\.`/`\|` message pause now holds for RPG_RT's real 16/61 frames, not
  a naive 15/60.** `\.` is documented as a quarter-second pause and `\|` as a
  full-second one, and at 60fps a literal reading gives 15 and 60 frames —
  which is what `Scene::Map::MSG_PAUSE_QUARTER`/`MSG_PAUSE_FULL` held. RPG_RT
  itself waits one frame longer than its own documentation in both cases
  (a reference implementation's message window ports this exactly, with
  source comments noting RPG_RT waits one frame longer than its documented
  1/4-second and 1-second pauses — not independently confirmed against
  genuine RPG_RT under wine), so every timed message pause in
  this engine was releasing one frame early. Fixed by correcting both
  constants to 16 and 61. Covered by two new `scripts/rpg2k_scene_check.rb`
  checks that drive a `\.`/`\|` pause end to end and count the exact number
  of frames it holds the reveal for, both confirmed to fail against the
  pre-fix code (15/60) before the fix.
