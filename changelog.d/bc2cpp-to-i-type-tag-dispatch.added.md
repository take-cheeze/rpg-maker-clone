- `tools/bc2cpp/bc2cpp.rb`'s `NATIVE_PRIMITIVE_SEND_ARITY` gains `to_i`,
  the one real winner out of a three-candidate survey (`to_i`,
  `include?`, `member?`) run against the remaining `POLY` native-dispatch
  call sites.

  `to_i` is registered by 7 real native functions across `3rd/mruby/src`
  and its gems (Integer, Float, String, Complex, NilClass, Rational,
  Time), but only 4 of those gems/classes are ever loaded by this
  project's own `build_config.rb` (mruby-complex/mruby-rational/
  mruby-object-ext are never `conf.gem`'d) -- Integer, Float, String, and
  Time are the only real, reachable implementations. `mrb_obj_itself`
  (Integer, a real public `MRB_API`, exactly `return self`) and
  `mrb_str_to_integer` (String, also public -- `mrb_str_to_i`'s own real
  body always resolves the optional base to 10 for the `n==0` shape this
  table's own arity gate is pinned to, confirmed by reading the whole
  function) are handled unconditionally. Float (`flo_to_i`) is handled
  for the common finite-and-in-range case only: NaN/Infinity (a real
  `FloatDomainError`) and anything too large for a native `mrb_int`
  (Bignum promotion) both need `mruby/internal.h`-only helpers with no
  public substitute, so that edge falls through to ordinary `mrb_funcall`
  -- the same "won't reach into internal.h for a function with no public
  equivalent" posture `to_s`'s own case already took deferring
  `mrb_mod_to_s`. Time (`time_to_i`) is deliberately excluded entirely:
  its own body reads directly from `struct mrb_time`, a type defined only
  inside mruby-time's own `time.c`, fully opaque anywhere else, with no
  public accessor for the raw epoch-seconds field. 45 real call sites
  flip.

  `include?`/`member?` were investigated too, individually sound (all
  four real `include?` native registrations -- Hash/Range/String/
  Class-Module-SClass -- are safely reproducible; Range's own case is
  literally the same function, `range_include`, already reimplemented
  for `===`'s own bucket) but excluded: `mruby-rgss/mrblib/
  array_include.rb` deliberately defines a real bytecode `Array#
  include?` (mruby's own Array has no native one), so `native_only_mono?`
  correctly refuses every time. `member?` is independently blocked by an
  unrelated `Game::Battle::Combatant#member?` (0-arg) and would need its
  own separate table entry regardless (dispatch is keyed by the literal
  call-site name, not an alias set). Neither added; documented in the
  table's own comment for a future round if either override is ever
  removed.

  Verified via a real whole-program regen diff (45 real `to_i` sites
  flip, zero unrelated diff) and an independent runtime test against a
  minimal `libmruby.a` (with mruby-time included this round): Integer,
  positive/negative Float truncation, String parsing (including a
  non-numeric string correctly yielding 0), and `Time#to_i` confirmed
  still falling through to real dispatch (`MRB_TT_DATA`/`MRB_TT_CDATA`).
  `scripts/rpg2k_logic_check.rb`/`scripts/rpg2k_scene_check.rb` both
  still pass, and `docs/bc2cpp_coverage.txt` needed no regeneration.
