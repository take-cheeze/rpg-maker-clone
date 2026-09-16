- `tools/bc2cpp/bc2cpp.rb`'s call-site devirtualization (`compile_send`'s
  MONO/TYPED paths) now also fires against a target whose own definition
  has plain positional optional arguments (`def foo(a, b = 1)`,
  OPTIONAL_ARG_SUPPORT) -- previously the call-site gate still required
  `pure_mandatory_arity?` (`opt == 0`) even though `compile_method` has
  compiled such a target's own body clean for a while, so every call site
  fell through to ordinary `mrb_funcall`, never straight to that target's
  real `_impl`, regardless of how many real callers existed. Two new
  helpers, `optional_arity`/`pure_mandatory_or_optional_arity?`, widen both
  the MONO and TYPED gates to accept any call-site argument count in
  `[mandatory_arity, mandatory_arity + optional_arity]` (an exact-match
  check when `optional_arity` is 0, unchanged from before); the call
  construction pads any optional position the call site didn't supply with
  `mrb_nil_value()` and appends the target's own `bc2cpp_given_opt` value
  as a trailing integer literal -- the identical placeholder/given-count
  convention `compile_method`'s own entry wrapper already uses for the
  ordinary `mrb_funcall`-dispatched path, just computed from the call
  site's own already-known argument count instead of a runtime
  `mrb_get_argc` call.

  Verified against a real whole-program before/after regen diff (all three
  compiled gems): 262 call sites flip from `POLY`/`mrb_funcall` to direct
  `MONO` calls (`RPG2k::Scene::Base#draw_system_text`,
  `Game::Battle#enemy_turn`/`#actor_turn`/`#actor_command`,
  `Game::State#timer`, `Game::Party#gain_item`/`#lose_item`/
  `#field_items`/`#cast_escape_skill`/`#cast_teleport_skill`/
  `#cast_switch_skill`, `Game::Actor#change_hp`/`#equip_item`, and others),
  zero unrelated diff lines, `#error` count unchanged. Runtime-verified
  independently of the whole-program build too: a standalone toy method
  (`def bar(a, b, c = 10, d = a + b)`) compiled through `bc2cpp.rb` in
  isolation, with three separate devirtualized callers (2/3/4 args given),
  linked against `libmruby.a` and run for real -- every devirtualized
  direct call matches the real mruby interpreter's own `mrb_funcall`
  dispatch of the identical call bit-for-bit, including the
  reference-an-earlier-argument default (`d = a + b`) case; a deliberately
  broken variant of the same test (swapping one call's own argument) was
  confirmed to actually fail, ruling out a vacuously-passing check.
  `scripts/rpg2k_logic_check.rb`/`scripts/rpg2k_scene_check.rb` both still
  pass unchanged.
