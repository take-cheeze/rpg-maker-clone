- **Wio Terminal:** the `wio`, `wio_walk` and `wio_rgss_boot` firmwares no
  longer link Seeed_Arduino_LCD's bitmap fonts 2/4/6/7/8, which nothing on
  the board draws. That saves 14,896 bytes of flash per firmware. The fonts
  are opted out through a guarded, no-op-by-default pre-build patch,
  `app/wio/patch_tft_espi_fonts.py`. See `docs/adr/0199`.
