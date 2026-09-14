- **Maix Amigo LCD capture**: `maix-smoke` now also boots the P0 firmware with
  LCD capture on -- a DMA copy hook replays each panel transfer into a log
  with its live DC bit -- and `scripts/maix_lcd_decode.py` replays the
  ST7789 stream into a framebuffer check (blue 320x240 screen, white text).
  See `app/maix/README.md` ("LCD capture").
