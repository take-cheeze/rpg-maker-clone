- **PSP: force an extra mruby GC pass once the fixed arena crosses 85% used,
  an experiment against P1c's `Scene::Map` crash.** `docs/adr/0047-psp-memory-
  budget.md`'s P1c crash (a `ppsspp-headless` segfault once the 12 MB mruby
  arena runs near full) survived hardening two real, independently-verified
  gaps in mruby's own `NoMemoryError` recovery
  (`patches/mruby-nomemoryerror-reentrant-alloc.patch`) -- a fresh CI run
  reproduced the exact same crash afterward. mruby's own GC threshold has no
  idea this arena has a fixed ceiling at all, so reclaimable garbage can sit
  around for a while between automatic collections, widening the window in
  which a real allocation falls back to the failure path that leads to the
  still-unhardened corrupting-unwind cliff. `app/psp/main.cxx`'s frame loop
  now forces `mrb_full_gc()` every 30 frames once arena usage crosses 85%,
  reclaiming that headroom earlier. Landed together with two real memory
  reductions (lazy call-only common events, shared LCF field-lookup
  tables); a `psp-smoke-game` run with all three together no longer
  crashes at all (previously guaranteed by `frame=200`) and reaches
  `frame=1600` cleanly, `arena_used` oscillating well clear of the ceiling
  instead of climbing into it -- see the ADR's P1c for the full numbers
  and the honest caveat that the underlying corrupting-unwind mechanism
  itself is still not hardened, only avoided for this game's workload.
