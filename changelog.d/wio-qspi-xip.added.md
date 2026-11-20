- **Wio Terminal: the compiled engine runs from the external 4 MB QSPI flash.** A `wio` link now fits the 512 KB
  internal flash and writes a second image, `firmware_qspi.bin`, for the QSPI flash. The new `wio_qspi_flash`
  environment programs that image from the microSD card (`docs/wio-qspi.md`). The `wio` link still overflows RAM.
