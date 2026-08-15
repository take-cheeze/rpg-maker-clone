- **A `\.` (quarter-second) message pause now stretches with the `\s[n]`
  typing speed in effect when it's reached, instead of always holding a
  flat 16 frames.** Confirmed against EasyRPG Player's source: a message
  typing speed of 17-20 stretches the quarter-pause by 1-4 extra frames —
  RPG_RT's own developers flagged this as a likely bug, but it's the real,
  observable behavior. The full-second `\|` pause is unaffected and stays
  flat regardless of typing speed.
