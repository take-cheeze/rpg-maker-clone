- `tools/bc2cpp/bc2cpp.rb` now compiles `ary.each { |x| ... }`
  literal blocks and `&:sym` block-pass sites (`reject(&:dead?)`,
  `map(&:succ)`, ...) -- the two cheapest halves of the `BLOCK`/`SENDB`
  gap, still the single largest remaining category (434 of 499
  uncompilable methods). Literal blocks inline as native C++ loops reusing
  ADR 0147's own machinery (outer-local capture and non-local `return`
  free); `&:sym` sites need no closure at all (one `mrb_funcall` per
  element plus accumulation). Every site is statically gated on a
  trace-proven Array receiver (`trace_new_target` + `ClassLayout`, new
  `ARRAY`-literal case) with an `mrb_array_p` raise-tripwire -- unproven
  sites keep the honest `#error`, never silent wrong dispatch into a
  `Game::Actors#each`-style override. Loops use live `RARRAY_LEN`
  (push-during-iteration visits new elements, matching the VM) and model
  `break`-with-value. Unlocks 27 real methods in
  `mruby-rpg2k-compiled` (1651 -> 1678 clean, zero regressions).
  Verified against a real runtime harness (11 each-literal + 7 sym +
  4 edge cases: live length, `__send__`, guard tripwire) plus end-to-end
  regen. See docs/adr/0152.
