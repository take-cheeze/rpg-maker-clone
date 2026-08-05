- RPG Maker **XP** message boxes draw the **pause arrow** — the blinking "press
  on" marker RGSS blits from the windowskin's 32x32 block at (160, 64), cycling
  its four 16x16 frames every eight frames, centred on the window's bottom edge.
  The genuine runtime draws it on every held text box, so its absence was a
  difference in every message frame of `scripts/compare-rpgxp-wine.bash`. A
  choice window does not get one, as in RMXP, where the cursor is the prompt.
