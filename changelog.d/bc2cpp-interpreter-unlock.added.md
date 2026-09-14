- `tools/bc2cpp/bc2cpp.rb` now unlocks the event interpreter: a
  `-> Array` return annotation feeds the block-receiver gate
  (`stat_targets` annotated; `mrb_array_p` tripwires verify every
  admitted site), `Range#each` inlines as a fixnum-counter loop
  (snapshot bounds, overflow-safe excl handling, Integer-edges guard),
  and `flat_map` compiles via the collect machinery with an
  Array-expansion tripwire -- plus an index-loop rewrite of
  `permanent_states`/`full_heal` as wiring-timing stopgap. +20 methods
  (1718 -> 1738 clean), zero regressions. Verified against runtime
  harnesses (gate, 12 Range cases, flat_map) plus end-to-end regen.
  See docs/adr/0157.
