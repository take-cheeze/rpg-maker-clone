- MV message-window smoke check: a new `--mv_message_test` flag drives the
  committed MV sample past New Game onto the map, queues a "Show Text" message
  through `$gameMessage`, lets `Scene_Map`'s `Window_Message` open and draw it,
  then logs `[MV-MSG] busy=<bool> window_open=<bool>` and captures a frame. It
  exercises the dialogue path every RPG uses (event → `$gameMessage` →
  `Window_Message` → text render), so CI confirms message boxes actually
  display. Wired as a non-blocking `build` job step alongside the existing MV
  boot/battle/movement smokes.
