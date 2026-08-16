- **PSP/Wio: mruby builds with the embedded tuning knobs.** The `psp` and
  `wio` mruby cross-builds in `build_config.rb` now pass
  `MRB_HEAP_PAGE_SIZE=256` (down from 1024 objects) and
  `KHASH_INITIAL_SIZE=16` (down from 32), the footprint-relevant half of
  mruby's own `MRB_CONSTRAINED_BASELINE_PROFILE` micro-controller set —
  `MRB_NO_METHOD_CACHE`, the third piece, is deliberately left out because it
  costs method-dispatch speed on a CPU-bound handheld. Smaller GC heap pages
  cut the slack an under-filled last page wastes, and smaller initial khash
  buckets shrink the symbol and instance-variable tables that start nearly
  empty, with no behaviour change. See `docs/adr/0047-psp-memory-budget.md`.
