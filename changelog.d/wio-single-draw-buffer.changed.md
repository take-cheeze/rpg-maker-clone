- The Wio firmware uses one 6.4 KB LVGL draw buffer instead of two: its
  display flush is synchronous, so the second buffer never overlapped a
  transfer.
