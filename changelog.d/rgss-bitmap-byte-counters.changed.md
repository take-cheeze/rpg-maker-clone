- **The PSP heartbeat now reports live decoded-`Bitmap`-buffer bytes,
  split into `bmp_decoded` (real asset pixels -- CharSet/Picture/Chipset/...)
  and `bmp_blank` (render targets, canvases, snapshots, and a `Bitmap#clone`'s
  own copy).** `Bitmap::buffer` lives in the plain C++ allocator, not the
  mruby arena (`docs/adr/0047-psp-memory-budget.md`'s Finding 3's "third
  pool"), and this build's only existing native-heap instrumentation
  (`sceKernelTotalFreeMemSize`/`MaxFreeMemSize`) turned out not to move at
  all across a full `psp-smoke-game` run despite real bitmap traffic, so it
  couldn't confirm anything about that pool. `mruby-rgss/src/lib.cxx`'s
  `Bitmap` now tracks two module-level byte totals through its own
  constructor/destructor/`operator=`, categorized by how the buffer's
  contents came to be rather than by entry count, so the two pools' very
  different growth shapes (one bounded by `mruby-rpg2k`'s new
  `LRUBitmapCache`, one not) are visible separately; `app/psp/main.cxx`
  surfaces both as new `bmp_decoded`/`bmp_blank` fields on every existing
  diagnostic marker, alongside `arena_used`.
