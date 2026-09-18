- **Maix Amigo CI (`maix-smoke`)**: broken on `master` since the panel-
  centering fix (PR #1747) legitimately changed the captured LCD extent
  from 320x240 to 480x320 (the LVGL canvas stays 320x240, now centered in
  the full panel with a cleared margin around it) without the CI job's
  `scripts/maix_lcd_decode.py` assertions being updated to match. Both
  affected checks (`Check red framebuffer`, `Check title framebuffer`)
  now expect `480x320` with a `--min-fraction` lowered to match the real
  color fraction diluted by the margin -- both re-measured directly under
  the same Renode setup CI uses, with headroom below the measured value,
  not at it. The P0 bring-up firmware's own check is untouched: it uses a
  separate direct ST7789 driver path, not `app/wio/src/maix_display.cxx`,
  and was never affected.
