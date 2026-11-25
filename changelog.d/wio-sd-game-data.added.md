- **Wio Terminal: game data on the microSD card.** The firmware reads the
  game's files from the card's `/rpg2k` folder (FAT12/16/32, Japanese names
  included) and falls back to the QSPI game image without one; the boot
  screen and the `[Wio]` log say which. `WIO_SD=0` builds without the card
  driver, whose code runs from the QSPI flash (about 2.8 KB of internal flash
  and 1 KB of RAM). See `app/wio/README.md`.
