- **Wio Terminal**: about 2.8 KB more of the 192 KB RAM is left for the game.
  The compiled code's class slots and class-constant caches now read const
  cells in flash for the classes the ROM class graph holds
  (`scripts/wio/rom_graph_cells.rb`), and the symbol names that were
  escaped byte by byte are now compile-time symbols.
