- **ADR 94 P3: a real ILI9341 display model for the Wio Terminal Renode
  platform.** Two new peripherals (`app/wio/renode/peripherals/`, built
  against a pinned Renode source commit via `scripts/wio_renode_build.bash`
  since nothing upstream models either): `SAMD51_SERCOM_SPI`, a real
  SERCOM-in-SPI-mode controller replacing P2's per-register stubs, and
  `ILI9341_SPI`, an SPI-command-stream-to-framebuffer model scoped to
  exactly what this firmware's `TFT_eSPI` fork sends. Verified directly —
  not just "it compiles" — with a new regression test
  (`app/wio/renode/lcd_smoke_test.resc`) that drives the LCD registers by
  hand and checks the resulting PNG's pixels land exactly where CASET/PASET
  windowing and RAMWR auto-increment addressing say they should. Driving it
  from real firmware instead is blocked on a newly-found performance
  limitation (`Seeed_Arduino_FS`'s SD retry timeout costs far more emulated
  instructions than wall-clock time on real hardware, since this model runs
  every SPI transfer instantaneously) and the DMA controller gap `wio`'s
  LVGL path needs — both documented as follow-up in
  `app/wio/renode/README.md` and ADR 94.
