- **Wio (Renode game ROM):** palette images are packed into the game ROM
  already decoded and read in place from the QSPI window instead of being
  decoded into the heap; a write copies one out first. `scripts/wio/game_rom.rb
  --bitmaps` picks what goes in (by default the map frame's material first, while
  the 16 MB window has room) and `RGSS_ROM_BITMAPS=0` copies entries into the
  heap instead.
