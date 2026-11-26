- **Wio:** the title screen now runs on the 192 KB board (Renode,
  `wio_renode_game`). A window's skin and cursor layers record their draws
  (`Bitmap#_defer`) instead of holding window-sized ARGB pixels, and the Wio
  expands a sprite's rows 1 KB at a time instead of 4 KB. New Game still runs
  out of memory before the first map frame.
