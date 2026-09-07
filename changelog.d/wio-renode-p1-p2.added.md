- **The Wio Terminal Renode platform from ADR 94 now boots real firmware**:
  `app/wio/renode/wio_terminal.repl` (a from-scratch clock-tree and SERCOM
  bring-up, not upstream's bare CPU-only stub) gets all three firmware
  environments (`wio`, `wio_walk`, `wio_sd_upload`) to their own `setup()`,
  and `wio`/`wio_sd_upload` to a stably-running `loop()`, with no board
  attached — `scripts/wio_renode_boot.bash` drives it. Along the way,
  ADR 94's assumption that Renode's `SAM_SPI` peripheral covered this board's
  SERCOM turned out to be wrong (it is the unrelated classic SAM4 "SPI" IP,
  checked against the upstream C# source), and a DMA controller gap was
  found in the `wio` firmware's LVGL flush path — both folded back into the
  ADR's phase plan. See `app/wio/renode/README.md` for the two non-obvious
  peripheral-stub pitfalls found getting the clock tree and SERCOM to boot
  without hanging.
