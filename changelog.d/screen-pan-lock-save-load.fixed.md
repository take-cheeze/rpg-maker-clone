- **Pan Screen's offset now survives a save/load.** A camera panned away from the
  hero is restored on Continue instead of snapping back to hero-centred, and a pan
  still scrolling when the game was saved keeps its offset. The Lock is not yet
  saved, so a locked camera still unlocks on Continue; `Game::Screen#load_h` is the
  restore side.
