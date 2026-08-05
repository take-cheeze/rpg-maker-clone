- RPG Maker **XP** message boxes are laid out the way RMXP's `Window_Message`
  lays them out — an inset 480x160 box sixteen pixels off the bottom of the
  640x480 screen, its text at x=4 of the contents — instead of spanning the full
  screen width at the very bottom (the RPG2000 layout it had inherited). The
  wine comparison against the genuine RGSS runtime took a map frame from 104,549
  differing pixels to 75,695 with the box on the reference's pixels.
