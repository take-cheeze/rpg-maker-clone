- **RPG2000/2003 maps: an autonomous (or custom-route) map event with a Move
  Frequency high enough relative to its own Move Speed raced far ahead of its
  own walk animation, snapping its logical tile forward every single frame
  instead of gliding at its configured pace.** `Scene::Map#step_event` paced
  an event's *next* movement decision purely off its `move_timer`
  (`EVENT_MOVE_DELAY[frequency]`, as low as 1 frame at frequency 8) with no
  regard for whether the *previous* decision's own multi-frame glide
  (`#walk_slide_step`, driven by Move Speed) had actually landed the event on
  its destination tile yet — unlike the party's own step input, which already
  refuses a new step while mid-slide (`return nil if @moving`). A slow Move
  Speed paired with a high Move Frequency (both settings a page can set
  independently, and exactly the combination Nepheshel's own wandering
  Map0007 puppet NPCs use — Move Speed "2"/frequency "8") let a fresh move
  decision fire long before the previous one's glide finished, moving the
  event up to a full tile every frame — dramatically faster than its Move
  Speed says it should travel. Real RPG_RT only resumes counting toward its
  next move once the character has actually stopped moving
  (`Game_Character::Update`'s `IsStopping()` gate; `UpdateMovement` resets the
  stop count to 0 on every frame a step is still in progress), so the Move
  Frequency wait runs entirely after a step lands, never overlapping it.
  Fixed by giving `#step_event` the same "still gliding? wait." gate the
  player's own input already has, via the existing `#event_sliding?` check.
  Three `scripts/rpg2k_scene_check.rb` checks that had themselves encoded the
  old racing-slide timing (their frame budgets assumed a new decision could
  fire mid-glide) needed their tick counts widened to match the corrected,
  no-longer-racing pace; a `scripts/rpg2k_command_soak.rb` run against the
  real Nepheshel data still completes clean.
