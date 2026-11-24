- **The RPG2000/2003 map** no longer keeps its two 336×256 tile layers and
  their two tile-grid caches as pixels (about 1.4 MB). They record their draws
  (`Bitmap#_defer`) and are composed a few rows at a time as each strip of the
  screen is drawn, with the same pixels on screen. `RGSS_DEFERRED_BITMAPS=0`
  (environment or build define) turns it off.
