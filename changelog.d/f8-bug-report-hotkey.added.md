- **F8 dumps a bug report**, from any scene (map, menu, battle, ...) and
  unlike the other debug hotkeys not gated on Test Play, so a real player can
  use it too. It writes a Markdown block ("Paste this whole block into the
  bug report") with the current map id, the hero's x/y/direction, each party
  member's HP/MP/level, the foreground interpreter's own state (running/
  waiting-on-what/command index), every live event on the map (id, x, y,
  direction, graphic, active page number, and — if a Parallel Process or the
  foreground interpreter is currently running its commands — that
  interpreter's command index and Call Event depth too), and the recent
  runtime log — to a timestamped `bugreport_<stamp>.md` next to the save
  data, and printed to stderr between fence markers so a terminal player can
  copy it straight out.
