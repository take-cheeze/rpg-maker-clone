- **The map renderer no longer draws the upper layer's reserved blank chip.**
  RPG2000's first upper-layer id (`BLOCK_F`) means "nothing on the upper layer
  here", and real map data is very nearly all of it — 98.45% of the 584,049
  upper cells across Nepheshel's 543 maps — so the renderer was blitting a
  fully transparent chipset cell roughly 330 times per grid rebuild for no
  pixels at all. Skipping it makes a rebuild 28% cheaper (16.5ms to 11.8ms),
  which is the spike that costs dropped frames, and leaves the rendered frame
  byte-identical. It is a *drawing* sentinel only: the blank id still indexes
  entry 0 of the chipset's upper passability table, and that lookup is
  untouched.
