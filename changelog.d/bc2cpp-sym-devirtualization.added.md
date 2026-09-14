- `tools/bc2cpp/bc2cpp.rb` now devirtualizes `&:sym` per-element
  calls: a MONO target (`out_of_play?`, 11 sites) compiles to a direct
  `_impl` call with no guard, and a small POLY target (`dead?`,
  `hidden`) to a per-element exact-class guard chain (cap 4) with an
  `mrb_funcall` fallback that is exact `Symbol#to_proc` semantics --
  never wrong, merely slower on miss. Native-only targets, over-cap
  sets (`dispose`, `update`), and unclean callees keep today's
  `mrb_funcall` byte-identically. Adds 10 clean methods in
  `mruby-rpg2k-compiled` (1678 -> 1688), zero regressions. Verified
  against a runtime harness (MONO, 4-branch POLY, foreign-element
  fallback, over-cap/native probes) plus end-to-end regen. See
  docs/adr/0153.
