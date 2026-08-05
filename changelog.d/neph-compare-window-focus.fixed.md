- The RPG Maker 2000 wine comparisons (`scripts/compare-nepheshel-wine.bash`,
  `scripts/compare-nepheshel-save-wine.bash`) focus each runtime's window before
  they synthesise a key, as the RPG Maker XP comparison already does. Both
  runtimes map a window and then resize it to the game's resolution, and when
  the resize wins that race the window manager leaves it unfocused: every key
  goes to the root window instead and the run reads as a runtime that ignored
  half the script.
