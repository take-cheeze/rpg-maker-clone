- **Wio Terminal**: the firmware now fits the board. The cold part of the
  engine runs in place from the 4 MB QSPI flash, so a `wio` build writes a
  second image, `firmware_qspi.bin`, which the new `wio_qspi_flash` loader
  programs (`app/wio/README.md`). A missing or mismatched image is reported on
  the LCD and the serial port.
