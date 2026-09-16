- **Maix Amigo TF card** now uses the K210's SPI1 peripheral instead of
  SPI0, matching the official schematic (every TF-slot net is literally
  named `SPI1_*` on the real PCB): the pin numbers were already right, but
  SPI0 is uniquely an "octal SPI" controller whose data lines are pin-shared
  with the DVP camera interface -- the same lines the LCD (also SPI0)
  claims for its own data bus -- so the TF card no longer has anything to
  arbitrate with the display, and the hand-rolled DVP-mux dance
  (`maix_spi_take_tf`/`maix_spi_take_lcd`) is gone. Confirmed on hardware
  that this was not the cause of the SD-boot hang (still open, see the
  `maix-game-sd-boot` entry), but it is a real correctness fix on its own.
