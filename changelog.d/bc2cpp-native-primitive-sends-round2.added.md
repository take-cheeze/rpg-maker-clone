- `tools/bc2cpp/bc2cpp.rb`'s `NATIVE_PRIMITIVE_SEND_ARITY` devirtualization
  (previously `!`/`nil?`/`is_a?`/`kind_of?` only) now also covers `equal?`,
  `class`, `object_id`, and `keys` -- found via a real whole-program survey
  of every `POLY`-tagged, whole-program-uncontested `mrb_funcall(` call
  site (2223 of them across 124 names, after fixing a stale-tag bug in the
  first pass of that survey that had misattributed opcode-level
  arithmetic-fallback calls to unrelated `POLY` tags several lines above
  them).

  That survey also surfaced a real, previously-unexamined soundness gap in
  `native_only_mono?` itself: the registry's own `'<native>'` marker
  collapses every native `mrb_define_method`/`MRB_MT_ENTRY` registration
  of a bare name into one synthetic entry, with no per-class tracking at
  all -- sound only for a name genuinely implemented once across all of
  mruby core (like the existing four), not for one implemented separately
  per built-in class. Verified against real mruby core source (not
  assumed) that several of the highest-count candidates are exactly that
  kind of trap: `to_s` (126 sites) resolves to eight different C
  functions (`mrb_ary_to_s`/`mrb_str_to_s`/`mrb_hash_to_s`/`int_to_s`/
  `flo_to_s`/`mrb_any_to_s`/`mrb_mod_to_s`/`range_to_s`), `length` (56) to
  three (`mrb_ary_size`/`mrb_str_size`/`mrb_hash_size_m`), `===` (374) to
  three (`mrb_eqq_m`/`mrb_mod_eqq`/`range_include`), and `min` (31) even
  collides across totally unrelated semantics (Array/Enumerable's minimum
  element vs `Time#min`, the minutes-of-hour accessor) -- hardcoding any
  of these by bare name the same way the existing four are handled would
  silently call the wrong native implementation the moment the receiver
  isn't the class assumed. Left alone for a future round that pairs each
  with a real receiver-class guard.

  The four added here were individually verified genuinely single-
  implementation, both via `3rd/mruby/src/*.c` source citations and a
  direct grep of every native registration actually reachable from this
  project's own closed world. `equal?`/`class`/`object_id` call their real
  public `MRB_API` functions (`mrb_obj_equal`/`mrb_obj_class`/
  `mrb_obj_id`) unconditionally, safe for any receiver (no struct cast
  inside any of the three). `keys` is different: `mrb_hash_keys` (also a
  real public API) casts its argument straight to `struct RHash*` via an
  unchecked macro, so a non-Hash receiver would be undefined behavior, not
  a clean `NoMethodError` -- it gets a real runtime `mrb_hash_p` (an
  RBasic-derived-struct type-tag check, `mrb_type(o) == MRB_TT_HASH`)
  guard before the direct call, falling back to ordinary `mrb_funcall`
  otherwise, mirroring the type-check guard `is_a?`/`kind_of?` already use
  for their own argument.

  Verified: a real whole-program regen diff (65 call sites flip from
  `mrb_funcall` to the new direct forms, `#error` count unchanged at 8,
  zero unrelated diff lines) and an independent runtime test against a
  minimal `libmruby.a` (every devirtualized direct call matches the real
  interpreter's own `mrb_funcall` dispatch bit-for-bit; a negative control
  confirms a non-Hash receiver's `keys` call correctly falls back to
  `mrb_funcall` -- a real `NoMethodError` -- without ever reaching the
  guarded native path). `scripts/rpg2k_logic_check.rb`/`scripts/
  rpg2k_scene_check.rb` both still pass, and `docs/bc2cpp_coverage.txt`
  needed no regeneration (none of the 65 flipped sites fall inside that
  report's own `ONLY_OWNERS` scope).
