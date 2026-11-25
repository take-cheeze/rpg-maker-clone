- **Wio (Renode game ROM):** `scripts/wio/game_rom.rb` packs the title
  graphics right after System, ahead of the map material. In the 16 MB window
  they used to miss the cut, so the title PNG was decoded into the heap at boot
  and ran the 192 KB board out of memory before the title's first frame.
