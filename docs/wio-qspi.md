# Wio Terminal: the external QSPI flash

The bc2cpp-compiled engine is about 3.4 MB, which is too big for the board's 512 KB internal flash. So it runs from
the 4 MB external QSPI flash, executed in place at `0x04000000` (`app/wio/qspi_xip.ld`). A `wio` link therefore
writes two images, and the board needs both:

| Image | Goes to | Written by |
|---|---|---|
| `.pio/build/wio/firmware.bin` | internal flash | `pio run -e wio -t upload` (the UF2 bootloader, as before) |
| `.pio/build/wio/firmware_qspi.bin` | external QSPI flash | the `wio_qspi_flash` loader below |

The UF2 bootloader cannot write the QSPI flash. Program it like this:

1. Copy `firmware_qspi.bin` to the microSD card as `/qspi.bin`, with a card reader or with
   `scripts/wio/sd_upload.py` (`wio_sd_upload`, see `app/wio/README.md`).
2. Run `pio run -e wio_qspi_flash -t upload`. Watch the serial monitor until it prints `DONE verified`.
3. Run `pio run -e wio -t upload`.

Both images come from the same link. If the QSPI image is missing, or comes from a different build, the firmware
does not start: it blinks the user LED instead. After every `wio` build that changes the engine, repeat all three
steps.

`wio_sim` (Renode) has no QSPI flash model, so a `wio` image built this way stops at that LED blink there.
