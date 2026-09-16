- **Maix Amigo LCD capture** now decodes correctly again after the display
  HAL's banded flush switched to a 16-bit-wide `tft_write_half` transfer:
  the Renode DMA hook was tagging every capture line with the DMAC's own
  (always-32-bit-padded) memory-access width, so the decoder silently
  treated half of every real pixel as a zero-padding phantom. The hook now
  reads SPI0's own frame-size register instead, and `maix_lcd_decode.py`
  unpacks `frame_bytes // 2` pixels per line -- `maix-smoke`'s red
  boot-screen and title-screen framebuffer checks pass again.
