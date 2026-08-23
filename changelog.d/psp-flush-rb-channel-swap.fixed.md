- **The PSP panel no longer shows red and blue transposed.** The PSP's 565
  display format is BGR-ordered (red in the low 5 bits) while LVGL's RGB565
  puts red high, so every pixel reached the panel with its red and blue
  channels exchanged — a known limitation noted in `flush_cb` since the HAL
  bring-up, harmless while only the idle status screen was drawn and visible as
  soon as real game graphics were. LVGL cannot do the conversion itself: its
  `RGB565_SWAPPED` is a *byte* swap for endianness, not a channel swap.
  `flush_cb` now rewrites each pixel on the way into VRAM instead of
  `memcpy`-ing the row, converting two pixels per 32-bit word where the row's
  alignment allows (a full 320×240 redraw is 76,800 pixels and this runs on
  every flush) with scalar handling for an odd leading pixel, an odd trailing
  pixel, and unaligned rows. Verified by dumping VRAM and decoding it as
  BGR565 — the order the display controller actually scans out — which now
  yields correct colours where it previously required an RGB565 decode.
