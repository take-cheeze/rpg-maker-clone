- `tools/bc2cpp/bc2cpp.rb` now compiles `receiver.times { |i| ... }` --
  the first real Ruby block (`BLOCK`/`SENDB`) shape this file supports,
  the single largest remaining gap since bc2cpp's own first version.
  Rather than building a real Proc/closure object, the block's own body
  is inlined directly into the enclosing compiled function as a native
  C++ loop, sharing the same registers -- which gets outer-local capture
  and a non-local `return` from inside the block for free, at no closure-
  machinery cost. Scoped to `#times` for this first round: it's the one
  real target with zero bytecode-defined overrides anywhere in this
  program's whole closed-world registry, so a runtime type guard that
  raises on mismatch is provably sound for every receiver, not just the
  common case (`#each` and the rest have real overrides in this program
  and need their own receiver-type story worked out separately). Unlocks
  16 real methods (2 in `mruby-rgss-compiled`, 14 in
  `mruby-rpg2k-compiled`). Verified against a real runtime harness
  (outer-local accumulation, `next`, a real non-local `return`, and a
  non-Integer receiver correctly raising) as well as the usual real
  end-to-end regen + `register.cxx` compile. See docs/adr/0147.
