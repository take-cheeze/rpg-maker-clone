- **Full-screen layers** keep their draws instead of 320×240 pixels: the RPG2000/2003
  map's fade, flash, weather, battle-animation and panorama layers and the flat
  battle backdrop (307,200 B each). A deferred bitmap also records
  `stretch_blt` now, and one that had to be materialized records again after a
  `clear` or a whole-bitmap `fill_rect`. Same pixels on screen.
