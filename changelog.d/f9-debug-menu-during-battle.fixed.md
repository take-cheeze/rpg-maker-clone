- **The F9 debug menu now opens during battle in Test Play.** RPG_RT's
  switch/variable editor was reachable from the field map only —
  `Scene::Map#try_open_debug_menu` was called solely from the main loop's
  non-busy branch, and `#event_busy?` is unconditionally true for as long as
  `@battle_ui` is set, so F9 silently did nothing for the entire duration of
  any fight. Per community RPG_RT trivia ("これは戦闘中でも行える" — this
  also works during battle), a battle no longer blocks it: `#drive_battle`
  now also polls for F9 each frame. Every other busy condition (a message
  window, an interpreter mid-wait) still gates the ordinary field-map case
  exactly as before.
