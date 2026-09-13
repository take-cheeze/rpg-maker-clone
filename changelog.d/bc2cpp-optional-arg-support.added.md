- `tools/bc2cpp/bc2cpp.rb` now compiles methods with plain positional
  optional arguments (`def foo(a, b = 1)`) -- the single largest remaining
  argument-handling gap (72% of the 160 real methods a closed-world survey
  found blocked by any non-mandatory argument shape). The real `ENTER`
  jump table mruby's own VM uses to skip already-supplied defaults is
  replayed as a native `switch`/`goto` on a new `bc2cpp_given_opt`
  parameter, so every default-value expression this file can already
  translate (a literal, a reference to an earlier argument, an ivar read)
  just works unmodified -- no new opcode needed. Devirtualization and ivar
  embedding are deliberately left untouched this round (an optional-arg
  method is still never a direct-call target and its `#initialize` still
  never embeds), matching this file's own established practice of shipping
  the compiler capability alone and wiring specific newly-unlocked methods
  into a shipped gem's `register.cxx` in a later coverage round. Unlocks
  115 real methods across the whole closed world (67 of them inside
  already-covered owners, confirmed via a real end-to-end regen: zero
  regressions, 56 in `mruby-rpg2k-compiled`, 11 in `mruby-rgss-compiled`).
  Also fixes a real, previously-latent bug found during this same
  verification pass: a Ruby local variable/argument name that happens to
  collide with a C++ reserved word (`RPG2k::Scene::Map#page_field`'s own
  `default` parameter) used to be emitted completely unescaped, a
  guaranteed compile error the moment that exact method ever became
  compile-clean. Verified against a real runtime harness (every jump-table
  entry from 0 through 3 optional arguments, `#send` dispatch, and a call
  supplying too many positional arguments correctly raising
  `ArgumentError`) as well as the usual real end-to-end regen +
  `register.cxx` compile (this time with `SKIP_UNSUPPORTED=1`, matching
  the real build exactly). Keyword arguments, `*rest`/`**kwrest`, and a
  block parameter remain unsupported. See docs/adr/0148.
