- **`RGSS::Bitmap#blur` and `#radial_blur`.** The last two `Bitmap` methods the
  stock VX Ace scripts call (one use each — the title background and the
  animation effects), and with them `Bitmap` is complete for that script set.
  - `blur` is a 3×3 box blur run over a **snapshot** of the bitmap, so every
    output pixel reads the original neighbourhood. Blurring in place would feed
    already-blurred pixels back in and smear along the scan order rather than
    evenly — the test pins the exact seam values a correct one produces (170 and
    85 either side of a white/black edge), which is what catches that.
  - `radial_blur(angle, division)` averages `division` copies of the image
    spread evenly over `angle` degrees and **centred on the original**, so the
    result is symmetric rather than smeared to one side. Samples that rotate off
    the bitmap contribute nothing, keeping the corners from pulling in
    transparent pixels. `division < 2` or `angle == 0` is the identity rather
    than a divide by zero.
  - Both average the channels **premultiplied by alpha**, so a transparent
    neighbour contributes weight but no colour instead of dragging colour out of
    an opaque pixel.

  These are pure pixel work, so unlike the recent rendering additions they are
  pinned in `mruby-rgss/test` rather than measured on a display. Worth noting
  what that took: the obvious `radial_blur` assertions — a flat fill comes back
  unchanged, a mark spreads — both pass even when the image is rotated about the
  *wrong point*, because a flat fill is invariant under any rotation and a mark
  spreads whatever it turns about. The test now asserts the swept arc is
  mirror-symmetric about the centre column, which does catch it.
