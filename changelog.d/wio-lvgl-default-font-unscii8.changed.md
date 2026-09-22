- **Wio Terminal:** the `wio` and `wio_rgss_boot` bring-up status screens now
  use LVGL's 1 bpp 8x8 `unscii 8` font instead of the anti-aliased
  Montserrat 14. That saves 12,304 bytes of flash; the labels are smaller
  but still readable. See `docs/adr/0200`.
