- **`RGSS::Input` key-repeat timing** now matches the genuine RPG_RT.exe
  (RPG Maker 2000 runtime), measured by holding a direction key on a title
  menu under wine and timing the cursor's moves: a held key repeats after 24
  frames (~400ms @60fps) instead of 30 (~500ms), then every 4 frames (~67ms)
  instead of every 6 (~100ms). This shared `Input` module backs RPG2k, RPGXP
  and RPGVX menu/map navigation, so the shorter, snappier repeat now applies
  across all three engines.
