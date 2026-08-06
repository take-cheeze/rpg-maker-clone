- **`Graphics.frame_reset` does what a game calls it for.** RGSS's frame pacing
  carries an absolute deadline, so after something slow — a map build, a big load
  — it owes a burst of short frames, which is exactly what a game calls
  `frame_reset` to avoid (`Scene_Map#transfer_player` and every map build do).
  It was a `warn_stub`, so every booted game printed "not implemented yet" on its
  way to the title screen: noise in the one log that is meant to be a bug list.
  It now drops the deadline, and the next frame starts counting from then. With
  it, a clean RGSS boot logs no stub warnings at all.
