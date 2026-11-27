- **Wio Renode runs** map a 32 MB game image window in every configuration,
  not only with `--heapwalk`, so a game in the QSPI image carries its palette
  images decoded the way the card pack does. Nepheshel's New Game now plays
  600 frames on the 192 KB board without an SD card.
