- `tools/bc2cpp/bc2cpp.rb`'s `BLOCK_CFUNC_FALLBACK_SUPPORT` (the cfunc/
  RProc fallback for a `BLOCK`/`SENDB` region no specific inliner
  recognizes) no longer rejects a block that reads `self` -- the
  restriction the previous round's own changelog explicitly flagged as
  the natural next step, now that the RProc capture mechanism was
  already in hand. `mrb_proc_get_self` (3rd/mruby/src/proc.c) still
  returns `self = nil` unconditionally for any CFUNC-backed proc, but
  this compiler doesn't need to ask it: it already knows the real value
  at the RProc's own CONSTRUCTION site (the enclosing method's own
  `self` C++ variable), so it captures it there via
  `mrb_proc_new_cfunc_with_env`'s one-slot env array and reads it back
  inside the block's own cfunc entry via
  `mrb_proc_cfunc_env_get(M, 0)` -- never trusting whatever (irrelevant)
  `self` mruby itself would pass to the entry point. `block_fallback_
  safe?` no longer needs its own `R0`-token/`SSEND`-family rejections at
  all; `GETUPVAR`/`SETUPVAR` (a real OUTER-LOCAL, as opposed to `self`)
  and `RETURN_BLK`/`BREAK` (non-local exit) are still rejected -- out of
  scope for this round, a natural follow-up now that the same env-
  capture mechanism exists to build on.

  A second, independent fix landed alongside this one, caught by an
  unexpected whole-program diagnostic regression while measuring the
  self-capture change's own real effect: `emit_block_fallback_fn` never
  checked whether the block body ITSELF compiled clean before wrapping
  it, unlike every other block emitter in this file (`emit_sort_inline`'s
  own explicit `return nil if body.include?('#error')`,
  `emit_times_inline`'s own caller comment). Nothing unsound could have
  shipped either way (`compiles_clean?`/`SKIP_UNSUPPORTED` already scans
  the WHOLE returned code string, this function's own embedded `#error`
  included), but a block body that itself hit some other still-
  unsupported opcode was silently getting wrapped in a real, pointless
  RProc anyway -- confirmed live: `BLKCALL`/`BLKPUSH`'s own whole-
  program `#error` counts ticked up by 1 each the moment this was
  missing (a block body using one of those two opcodes). Fixed with the
  same `return nil if body.include?('#error')` gate every other emitter
  already holds itself to, and its caller updated to skip the region
  entirely on `nil` (matching `emit_sort_inline`'s own `next unless
  inlined`).

  Verified via a real whole-program regen (fresh, correctly-patched host
  `mrbc`): `BLOCK_FALLBACK` sites 36 -> 65 (self-capture alone would have
  measured 66, but the ALL_OR_NOTHING_SUPPORT fix above correctly
  excludes the one site whose block body itself hits an unsupported
  opcode). 18 more methods move from `#error` to compiling clean
  (`compiled clean` 1988 -> 2006), whole-program `#error` total
  739 -> 681 (BLOCK 306 -> 277, SENDB 283 -> 256, SSENDB 36 -> 34; every
  OTHER `#error` reason, including `BLKCALL`/`BLKPUSH`, unchanged from
  baseline -- confirming the ALL_OR_NOTHING_SUPPORT fix). Inspected the
  real generated code directly for a genuine ivar-reading example
  (`Game::Enemy#initialize`'s own block-fallback body: `mrb_iv_get(M,
  self, "@attribute_ranks")`, where `self` is now the correctly captured
  value, confirmed by tracing the full chain from
  `mrb_proc_new_cfunc_with_env(M, fn, 1, { self })` at the construction
  site through to `mrb_proc_cfunc_env_get(M, 0)` inside the entry
  point). `bash scripts/bc2cpp_coverage_check.bash`: fresh. `scripts/
  rpg2k_logic_check.rb` (1201 checks), `scripts/rpg2k_scene_check.rb`
  (1062 checks), `scripts/lcf_testbed_check.rb` all still pass. A full
  whole-program `g++ -fsyntax-only` compile wasn't reachable in this
  session's own sandbox (no SDL2 devshell); instead, directly compiled a
  minimal `g++ -std=c++17 -fsyntax-only` smoke test reproducing the
  exact new `mrb_proc_new_cfunc_with_env`/`mrb_proc_cfunc_env_get`/
  `mrb_iv_get` call shape against this repo's own real mruby headers --
  clean.
