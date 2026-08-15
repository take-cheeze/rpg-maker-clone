- A Switch or Escape skill played no sound at all on a successful field
  cast (only a Buzzer on failure). Real RPG_RT plays the skill's own
  database `sound_effect` field instead — `Scene::SkillMenu` now does too,
  reusing the same `Array1D`/`SE` struct read `scene/title.rb#play_cursor_se`
  already established, and no-oping silently on a blank/absent filename.
  Teleport is unaffected: it already plays the ordinary decision SE, matching
  real RPG_RT.
