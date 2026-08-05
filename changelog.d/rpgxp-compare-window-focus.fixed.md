- `scripts/compare-rpgxp-wine.bash` focuses each runtime's window before it
  synthesises a key. Both runtimes map a window and then resize it to the game's
  resolution, and when the resize won that race the window manager left the
  window unfocused, every key went to the root window instead, and the run
  reported the whole map as differing -- a harness artifact that reads exactly
  like an engine that ignored New Game and sat on the title screen.
