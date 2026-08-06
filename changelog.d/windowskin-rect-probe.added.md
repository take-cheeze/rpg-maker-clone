- **The RMXP windowskin source rectangles are measured rather than assumed.**
  `RGSS.windowskin_rect_probe` (part of `--rgss_effect_probe`, run under Xvfb)
  paints each source region of a synthetic skin its own primary — the background
  tile, the four frame corners and the top edge — renders a window from it and
  reads back which colour landed where. The existing `window_probe` could not:
  it uses a deliberately flat skin, so it measures the area a window covers and
  every source rect could be wrong while it still passed. The new probe was
  confirmed to catch a wrong rect, by pointing the top-right corner at the
  top-left one and the background at the frame and watching each fail.
