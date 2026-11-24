- **Wio**: a sprite showing a zero-width or zero-height bitmap no longer halts
  the board in LVGL's null-buffer assert (`lv_canvas_set_buffer`), which stopped
  the Renode game firmware right after start-up. It now shows nothing, as it
  does everywhere else.
