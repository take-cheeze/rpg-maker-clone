- **ADR 94 P4: the Wio Terminal Renode platform can attach a real SD card,
  and a real limitation on what that buys today.** Renode's own `SD.SDCard`
  turned out to already implement SD-over-SPI directly (`spiMode: true`,
  confirmed by reading `Transmit()` itself — a correction to this ADR's
  earlier claim that nothing upstream spoke the SPI-mode wire protocol), so
  P4 needed no new peripheral: `scripts/wio_renode_sdcard.bash` builds a
  real FAT16 card image (`mkfs.vfat`/`mtools`) holding a real Nepheshel
  export and a `.repl` snippet layering it onto `sercom6_spi`. Attaching a
  working card did not, however, unblock `wio_walk`'s render path the way
  hoped — register-level inspection (not just `PC` sampling, which produced
  a false "memory corruption" reading the first time by catching a register
  before the faulting instruction had written it) shows the firmware is
  genuinely still processing real `TFT_eSPI` LCD-init traffic, not SD, when
  it runs out of budget: `TFT_eSPI::init()` alone has ~295 ms of
  unconditional `delay()` calls before `SD.begin()` is ever reached, and
  every `delay()`/`millis()`-bound wait anywhere in this firmware costs
  vastly more emulated instructions than wall-clock time on real hardware,
  since this platform runs every SPI transfer instantaneously. That
  delay()-cost problem — not a missing SD peripheral — is now this
  platform's real blocker. A 30-virtual-second attempt to run past it hit a
  second, unrelated problem after ~5 real minutes: an unhandled
  `SemaphoreFullException` in Renode's own `ConsoleIOSource.HandleInput()`,
  a genuine upstream stability bug on long headless runs with stdin
  redirected from `/dev/null`, not anything in this platform. See
  `app/wio/renode/README.md` and ADR 94 for the full writeup and two more
  debugging pitfalls found chasing this down.
