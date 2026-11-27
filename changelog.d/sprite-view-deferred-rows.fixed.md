- **A sprite drawn narrower than its deferred bitmap no longer composes
  oversized rows.** The per-strip buffer was sized from the sprite's drawn
  width, but a deferred bitmap composes rows of its own full width, so a
  cropped sprite over a 336-pixel map layer asked for a 13 KB buffer mid-draw.
  That allocation was the 192 KB Wio's out-of-memory on the first map frame.
  The strip is now capped at the same 1 KB (4 KB on the host) by the bitmap's
  width, and draws the same pixels.
