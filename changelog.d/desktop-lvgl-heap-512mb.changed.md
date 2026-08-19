- **Desktop build** the LVGL memory pool grows again, 256 MB → 512 MB (see
  `changelog.d/desktop-lvgl-heap-256mb.changed.md` for why it backs
  everything, not just graphics). The first bump only covered a real VX Ace
  release's database load; past that and the `Dir.glob`/`Color`/`Tone` fixes
  in this same release, the script host reaches actual scene construction —
  the title screen's own windows, sprites and bitmaps — a second, larger
  consumer 256 MB did not cover, aborting with `NoMemoryError` mid-boot even
  with a fully loaded database. The PSP and Wio builds keep their own
  separately-tuned pools; this only raises the desktop ceiling.
