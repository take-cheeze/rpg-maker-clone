- **ADR 94 P4: the Wio Terminal Renode platform can attach a real SD card.**
  Renode's own `SD.SDCard` turned out to already implement SD-over-SPI
  directly (`spiMode: true`, confirmed by reading `Transmit()` itself — a
  correction to this ADR's earlier claim that nothing upstream spoke the
  SPI-mode wire protocol), so P4 needed no new peripheral:
  `scripts/wio_renode_sdcard.bash` builds a real FAT16 card image
  (`mkfs.vfat`/`mtools`) holding a real Nepheshel export and a `.repl`
  snippet layering it onto `sercom6_spi`. Attaching a working card at first
  did not unblock `wio_walk`'s render path the way hoped; that turned out to
  be two real, fixable bugs rather than a platform-wide performance limit —
  see the `wio-renode-bugfixes` fragment and `app/wio/renode/README.md` for
  the corrected account, and ADR 94 for the full writeup.
