- `tools/bc2cpp/bc2cpp.rb`'s `NATIVE_PRIMITIVE_SEND_ARITY` gains `===`,
  continuing the `to_s`/`length`/`first`/`dup` round's own type-tag-
  dispatch pattern: a real grep across `3rd/mruby/src` finds `===`
  registered separately on Object/Kernel (`mrb_eqq_m`), Class/Module
  (`mrb_mod_eqq`) and Range (`range_include`) -- three distinct native
  bodies the registry's own `<native>` placeholder collapses into one
  entry. All three are `static` and read their argument via
  `mrb_get_arg1` (a call-frame read, unsafe to call directly -- the same
  trap every other multi-implementation name in this table already has),
  but each one's logic is trivially and safely reproducible from
  genuinely public, direct-parameter `MRB_API`s: `mrb_mod_eqq` becomes
  `mrb_obj_is_kind_of(M, arg, mrb_class_ptr(recv))`; `range_include`'s
  real body is reproduced inline using the public `mrb_range_beg`/
  `mrb_range_end`/`mrb_range_excl_p` macros plus `mrb_cmp` (both already
  used elsewhere in this file's own #each-inlining and #sort codegen)
  standing in for `range.c`'s own static `r_le`/`r_gt`/`r_ge` one-line
  `mrb_cmp` wrappers; `mrb_eqq_m` becomes `mrb_bool_value(mrb_equal(M,
  recv, arg))` for Integer/Float/String/Symbol/True/False/Nil/Array/Hash
  (`mrb_equal` is side-effect-free and safe for any receiver, so -- unlike
  `to_s`'s own Array/Hash exclusion for a real `ci->mid`-mutation bug in a
  *different* native function -- there is nothing to exclude here).
  Deliberately excludes `MRB_TT_DATA` (mruby-onig-regexp's `Regexp`
  registers a real, active BYTECODE `#===` override that
  `closed_world_mrblib_srcs` can't see, since it never scans that gem's
  own mrblib -- a real registry blind spot, not a false negative in
  `native_only_mono?` itself; `MRB_TT_DATA` is also shared by
  mruby-marshal/mruby-stringio/mruby-rgss's own wrapper objects) and
  `MRB_TT_PROC` (mruby-proc-ext's bytecode `Proc#===`, confirmed not part
  of this project's real dependency graph today, excluded anyway as cheap
  insurance). Note this mruby build has no separate `MRB_TT_NIL` tag at
  all -- nil and false both report `MRB_TT_FALSE` from `mrb_type`,
  distinguished only by a hidden flag bit -- caught by an actual g++
  compile of the generated switch against a real `libmruby.a` before this
  landed (an initial draft's stray `case MRB_TT_NIL:` was a real compile
  error, not just a redundant case).

  This is on top of, and reuses, `LITERAL_EQQ_SUPPORT`'s own existing
  `case/when`-on-literal devirtualization (`eqq_literal_devirt_safe?`),
  which still runs first and returns early for its own narrower Symbol/
  Fixnum-literal-receiver shape -- this round's own switch only ever
  fires for the POLY `:===` call sites that mechanism doesn't reach
  (confirmed via a background research pass: 374 real whole-program call
  sites, dominated by `case/when` on a scoped Integer constant, e.g.
  `Game::Battle::RESTRICTION_*`, or a String literal format-char dispatch
  -- zero Range or Class/Module receivers observed in this program, but
  handled anyway since the real registrations cover them for free).

  Verified via a real whole-program regen diff against a properly patched
  host mrbc (374 `POLY :===` sites flip, all 748 removed lines matching
  exactly the two known `// POLY :===` tag/`mrb_funcall` line shapes, zero
  unrelated diff) and an independent runtime test against a minimal
  `libmruby.a`: every Integer/Float/String/Symbol/true/false/nil/Array/
  Hash equality case, every Range boundary (inclusive/exclusive,
  open-ended `beg`/`end`), Class/Module `kind_of?`-style membership, and a
  custom Object-receiver `#===` override (confirmed still going through
  ordinary `mrb_funcall`, not the native switch) all matched real
  `mrb_funcall`-based dispatch exactly. `scripts/rpg2k_logic_check.rb`/
  `scripts/rpg2k_scene_check.rb` both still pass, and `docs/
  bc2cpp_coverage.txt` needed no regeneration.
