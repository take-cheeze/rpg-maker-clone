- **The built-in profiler now reports live mruby objects by type.** A new
  vendored patch (`patches/mruby-gc-type-live-counts.patch`) adds a per-type
  live/allocation counter pair to mruby's GC, kept current by a single
  increment in `mrb_obj_alloc()` and a single decrement in the sweep phase's
  `obj_free()` — unlike `ObjectSpace.count_objects`, which forces a full GC
  before every call, this costs nothing beyond an O(30) memcpy to read. The
  `--profile` stderr summary line gains a `types:` field (top eight, most-live
  first), `RGSS::Profiler.stats` exposes the full breakdown as `:object_types`
  (class name to `:live`/`:allocs`), and a Chrome trace (`--profile_trace`)
  mirrors it as a `mruby_types` counter series.
