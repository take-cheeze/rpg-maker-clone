- **Maix Amigo game-from-SD firmware** (`maix_game_sd`, reads `/sd/maixgame/`
  pushed with the serial uploader instead of the flash-embedded copy)
  compiles and mounts the card, but does not boot yet: on real hardware it
  hangs solid partway through the interpreter's first data-cluster read,
  isolated to below the vendor SD library's own read timeout (likely the
  K210 SPI HAL's untimed FIFO wait) -- not a Renode target (no SD
  controller modeled), so this is compile-proof only in CI for now. See
  `app/wio/src/maix_game_main.cxx`'s KNOWN ISSUE comment for the trail.
