- `tools/bc2cpp/bc2cpp.rb`'s `NATIVE_PRIMITIVE_SEND_ARITY` gains `!=`, the
  one real winner out of a five-candidate survey (`push`, `!=`, `size`,
  `empty?`, `<<`) found by tallying this program's own remaining `POLY`
  native-dispatch call sites.

  `!=` turned out not to be backed by any C function at all:
  `3rd/mruby/src/class.c`'s own `bob_init` registers it via a hand-written
  static bytecode `RProc` (`neq_proc`/`neq_irep` -- literally `OP_ENTER,
  OP_EQ, OP_JMPNOT, OP_LOADFALSE/OP_LOADTRUE, OP_RETURN`, i.e. `!(self ==
  other)`) through `mrb_define_method_raw`, a registration idiom
  `extract_native_method_names` never recognized at all -- without that
  gap fixed (this file's own third scan added alongside this entry,
  covering the only two other real literal-token call sites of that
  idiom: `Class.new` and `Proc#call`/`Proc#[]`, neither of which needed a
  new NATIVE_PRIMITIVE_SEND_ARITY entry), `!=` had no registry entry
  whatsoever and this would have been silent dead code forever.

  Real `OP_EQ` (`3rd/mruby/src/vm.c`) is an identity check first, then --
  only for a Symbol receiver -- a hardcoded `false`, then an Integer/Float
  fast path or a real `SEND :==` dispatch. The real public `mrb_equal`
  MRB_API (already trusted for `===`'s own equality bucket) was verified
  to reproduce this exactly for every type, including the Symbol
  hardcoded case (its own `mrb_func_basic_p` check reaches the identical
  `false` answer generically) -- so `!mrb_equal(M, recv, arg)` is a full,
  unconditional, no-fallback-needed reproduction of `!=` for any
  receiver, the same "no third implementation to miss" shape `dup`
  already has. 234 real call sites flip.

  The other four candidates were fully investigated and are each
  genuinely safe as a *mechanism* (`push`/`n==1` and `<<`'s Array arm via
  the real public `mrb_ary_push`; `<<`'s String arm via `mrb_str_concat`,
  guarded to only fire when the argument is ALSO a String -- `str_concat_m`
  treats an Integer argument as a Unicode codepoint, a real, silent
  divergence from what `mrb_str_concat` itself does for one; `empty?` via
  `mrb_ary_empty_p`/`mrb_hash_empty_p`/`RSTR_LEN` combos, all three
  side-effect-free; `size` identical to `length`'s own two functions) --
  but a direct check against this program's own live whole-program
  registry (not assumed) showed all four genuinely collide with a real
  bytecode override somewhere in the closed world: `RPG2k#push`,
  `Game::Party#size` (plus an unrelated native `RGSS::Font#size`, a third
  distinct implementation `length`'s own two-function story doesn't
  cover), `Game::MoveRoute#empty?`, `RGSS::ErrorReport::Tee#<<`. The
  existing `native_only_mono?` gate correctly refuses all four every
  time -- confirmed with a temporary debug probe against the live
  registry, not just inferred -- so an entry for any of them would be
  real, unreachable code shipped for zero measured benefit today. Left
  out entirely rather than shipped inert.

  Verified via a real whole-program regen diff (`!=`'s own 234 sites
  flip, zero unrelated diff) and an independent runtime test against a
  minimal `libmruby.a`: Integer/Float mixing, String, Symbol, nil vs.
  false (this build has no separate `MRB_TT_NIL` tag -- nil and false
  share `MRB_TT_FALSE` -- confirmed the two are still told apart
  correctly), Array, and a custom class overriding `==` to always return
  `true` (confirmed `mrb_equal` still re-dispatches to it correctly).
  `scripts/rpg2k_logic_check.rb`/`scripts/rpg2k_scene_check.rb` both
  still pass, and `docs/bc2cpp_coverage.txt` needed no regeneration.
