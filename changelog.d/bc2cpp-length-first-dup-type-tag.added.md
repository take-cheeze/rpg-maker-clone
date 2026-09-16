- `tools/bc2cpp/bc2cpp.rb`'s `NATIVE_PRIMITIVE_SEND_ARITY` gains `length`,
  `first`, and `dup`, continuing the `to_s` round's own type-tag-dispatch
  pattern -- each of these three is also registered by more than one
  distinct native C function across mruby core, so each gets its own real
  `mrb_type(recv)`-based dispatch (or, for `dup`, an exhaustive one with no
  `mrb_funcall` fallback at all) rather than a single unconditional call.

  `length`: `mrb_ary_size`/`mrb_hash_size_m` (Array/Hash) are handled
  directly -- both clean, side-effect-free, and either already-public or
  built from public macros/API. `mrb_str_size` (String) is deliberately
  excluded: its own body reads `RSTRING_CHAR_LEN`, a macro defined twice
  *inside* `string.c` itself (never in a public header), gated on this
  project's own `MRB_UTF8_STRING` build flag -- reproducing it here would
  be a silent, unstated coupling to that flag's current value rather than
  a proven-safe simplification. 56 real call sites flip.

  `first`: only `Range#first` (`range_beg`, a real separate `ARGS_NONE`-
  only registration, exactly `mrb_range_beg`, a real public macro) is
  handled directly. `Array#first` (`mrb_ary_first`), despite having a
  single real implementation too, is deliberately excluded: its own body
  reads `mrb_get_argc(mrb)` to pick between its "bare `x.first`" and
  "`x.first(n)`" behaviors -- calling it directly from generated code
  would read the WRONG call frame's argument count, the same stale-call-
  info-frame trap `monomorphic_target`'s own comment already warns about
  for an arbitrary native function, just for `mrb_get_argc` instead of
  `mrb_get_args`. 27 real call sites flip (the `n=1` "first N elements"
  call shape this same survey also found never reaches this table at all
  -- a different arity, so it stays ordinary `mrb_funcall`, untouched).

  `dup`: the one entry in this whole table with NO `mrb_funcall` fallback
  arm at all -- a full grep across every native source this project's own
  closed world can see found exactly two real registrations,
  `mrb_obj_dup` (Kernel's own default, a real public `MRB_API`, correct
  for literally any receiver except a Class/Module/singleton-class
  instance -- even honors a real `#initialize_copy` override, since its
  own body dispatches that through the ordinary method-call mechanism)
  and `mrb_mod_dup` (Module's own override for that one case -- static,
  but its three-line body is reproduced directly). 25 real call sites
  flip.

  All three verified via a real whole-program regen diff (`#error` count
  unchanged at 8, zero unrelated diff lines) and an independent runtime
  test against a minimal `libmruby.a` covering every direct-dispatch
  branch plus each one's own fallback path (String#length, Array#first
  including the empty-array/nil case, and both the Kernel-default and
  Module-override `dup` paths). `scripts/rpg2k_logic_check.rb`/`scripts/
  rpg2k_scene_check.rb` both still pass, and `docs/bc2cpp_coverage.txt`
  needed no regeneration.
