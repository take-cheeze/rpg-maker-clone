- **ADR 94's Wio Terminal Renode platform no longer live-locks booting
  `wio_walk`/`wio_sd_upload` with a real SD card attached.** Two real bugs,
  not a platform-wide `delay()`-cost limitation as earlier documented here:
  (1) `app/wio/renode/peripherals/SPI/SAMD51_SERCOM_SPI.cs` only implemented
  `IDoubleWordPeripheral`, but the Arduino SAMD core's SERCOM driver polls
  `INTFLAG` with a byte (`ldrb`) access for every SPI byte transferred —
  Renode does not auto-bridge a byte access to a DoubleWord-only peripheral,
  so the poll spun forever reading back 0 (silently logged at `NOISY`
  level). Fixed by adding `IBytePeripheral.ReadByte`/`WriteByte`, delegating
  to `ReadByteUsingDoubleWord`/`WriteByteUsingDoubleWord`. (2) Upstream
  `SD.SDCard` doesn't implement `ACMD42` (`SET_CLR_CARD_DETECT`), which
  `Seeed_Arduino_FS` sends unconditionally during `SD.begin()` and treats a
  (correct) illegal-command response to as fatal; fixed via
  `app/wio/renode/patches/sdcard-acmd42.patch`, applied automatically by
  `scripts/wio_renode_build.bash`. With both fixed, `wio`, `wio_walk` and
  `wio_sd_upload` all reach their own `loop()` reliably and fast, including
  `wio_walk` with a real SD card getting through `SD.begin()` and its
  backdrop fill. See `app/wio/renode/README.md`'s "Two real bugs found and
  fixed getting here, not a platform limitation" section and ADR 94 for the
  full corrected account (the DMA controller gap — affecting both `wio` and
  `wio_walk`'s tile/frame push, not just `wio` as previously stated — is
  still what stops a full render).
