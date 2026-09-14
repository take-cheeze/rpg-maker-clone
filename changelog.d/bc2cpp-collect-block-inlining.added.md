- `tools/bc2cpp/bc2cpp.rb` now compiles `map`/`select`/`reject`/
  `find`/`each_with_index` literal blocks (162 sites, the largest
  remaining `BLOCK`/`SENDB` cluster after ADR 0152) as native loops on
  the same inline machinery: yielded values captured per iteration
  (`next`-without-value collects nil, matching the VM),
  method-specific result slots (fresh Array, filter, first-match,
  index binding), and `break`-with-value guarded by a dedicated
  broke-flag so a partial accumulator never overwrites it. Same
  static Array gate + raise-tripwire, same live-length loop. Unlocks
  27 methods (25 in `mruby-rpg2k-compiled`, 2 in `mruby-lcf-compiled`),
  zero regressions. Verified against a runtime harness (11 cases
  including the harness-caught break-overwrite bug) plus end-to-end
  regen. See docs/adr/0154.
