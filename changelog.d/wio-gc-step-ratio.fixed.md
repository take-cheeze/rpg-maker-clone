- **Wio Terminal**: the garbage collector now does five times as much work per
  incremental step. Loading a large map no longer runs through one unfinished
  collection that frees nothing. On Nepheshel's map 355 the heap peak drops
  from about 1730 KB to about 1180 KB, and on map 120 from about 840 KB to
  about 720 KB.
