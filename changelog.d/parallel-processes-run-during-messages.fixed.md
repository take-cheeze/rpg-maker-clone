- **Background parallel processes now keep advancing during a message
  window or while a foreground event is parked on a blocking wait**
  (Show Text, Wait, ...), matching yado.tk: real RPG_RT only suspends them
  for the Menu and Battle screens, not for an ordinary message box.
  `Scene::Map#step_parallels` runs every frame now, gated by a narrower
  `#parallels_paused?` (true only during battle, or while the foreground
  interpreter is actively grinding through non-blocking commands) instead
  of the old, much broader `event_busy?`.
