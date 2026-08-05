- RPG Maker **XP** events can now **Change Screen Color Tone** (command 223).
  The map scene puts its ground, the party and the event sprites into one
  screen-sized viewport — RMXP's `Spriteset_Map` `@viewport1` — so the tone
  rescales the map and leaves the windows above it alone, and the value eases
  toward its target over the command's duration without suspending the
  interpreter (as `Game_Screen#start_tone_change` does). Pray for You tints its
  whole opening; against the genuine RGSS runtime under wine that took a map
  frame from 298,738 differing pixels to 104,549.
