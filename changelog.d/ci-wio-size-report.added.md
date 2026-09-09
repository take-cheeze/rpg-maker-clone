- **CI:** the `wio` job now posts a flash/RAM job-summary table for the
  three Wio Terminal firmwares it builds (`wio`, `wio_walk`,
  `wio_sd_upload`) -- `scripts/wio_size_report.rb` reformats the RAM:/Flash:
  usage lines `pio run` already prints after linking each one, so the SAMD51
  512 KB flash / 192 KB SRAM budget this project's ADR 91+ downsizing series
  tracks by hand in each ADR is also visible on every CI run without
  digging through the raw build log. Does not cover `env:wio_rgss_boot` (the
  environment those ADRs actually measure) -- that build needs a separate
  ARM cross-build of mruby + uni-algo (`WIO_MRUBY_BUILD_DIR`/
  `WIO_UNIALGO_LIB_DIR`) CI does not currently produce, so it stays a
  manual, real-relink measurement per ADR as before.
