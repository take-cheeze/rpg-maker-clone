- Fixed a real, pre-existing argument-count bug in the opt-in
  (`RPGMAKER_BC2CPP=1`) AOT compiler's `KEYWORD_CALLSITE_SUPPORT` MONO
  devirtualization path that made the whole-program generated C++ fail to
  compile at 17 call sites. `compile_keyword_call` emitted a uniform
  `(value, presence_flag)` pair for every entry in the callee's keyword
  table, but `compile_method`'s own `_impl` signature builder emits the
  extra `mrb_int bc2cpp_kw_given_<name>` parameter for an **optional**
  keyword only (`unless kw[:required]`) -- a required keyword is always
  given, since `mrb_get_args` itself raises `ArgumentError` first, so it
  carries no flag. The entry wrapper's own `_impl` call already got this
  right (`kw[:required] ? [value] : [value, given]`); only the
  devirtualized direct call disagreed, shifting every later argument by
  one slot per required keyword. Real `g++ -std=c++17 -fsyntax-only` of
  the actual `SKIP_UNSUPPORTED=1` whole-program output: **17 errors ->
  0** (zero errors, zero warnings), in two spellings that were the same
  bug, differing only in whether the shifted argument still had a
  parameter to land in:
  - 12 x `could not convert '1' from 'int' to 'mrb_value'` --
    `RPG2k__Scene__Map_anim_target_impl(M, self, r6, r7, r9, 1, r11, 1,
    r13, 1)` against a real signature of `(mrb_state*, mrb_value self,
    mrb_value tx, mrb_value ty, mrb_value bc2cpp_kwarg_height, mrb_value
    bc2cpp_kwarg_index, mrb_value bc2cpp_kwarg_flash_target)` (three
    required keywords, three stray flags); and
    `Game__Battle_command_skill_all_impl(M, self, r9, r10, r12, 1, r20,
    1, ...)`, whose required `name`/`cost` pair put the literal `1` in
    the `mrb_value bc2cpp_kwarg_cost` slot. Now
    `(M, self, r6, r7, r9, r11, r13)` and `(M, self, r9, r10, r12, r20,
    r22, 1, ...)` respectively -- flags kept for optional keywords only.
  - 5 x `too many arguments to function 'mrb_value
    RPG2k__Scene__Map_vehicle_blocks__impl(mrb_state*, mrb_value,
    mrb_value, mrb_value, mrb_value)'` -- one required `block_airship:`
    keyword left `(M, self, r6, r7, r9, 1)` one argument past the end of
    a signature with no trailing slot to absorb it. Now `(M, self, r6,
    r7, r9)`.

  The fix is one change at the single shared emitter, so it covers both
  the ordinary `n=N|nk=K` keyword call site (`compile_keyword_send`) and
  the unrolled splat/double-splat one (`compile_splat_send`), and every
  keyword shape this file supports (`OPTIONAL_KEYWORD_COMBINED_SUPPORT`'s
  optional+keyword methods included -- `Game::Battle#command_item`'s real
  mixed table still emits `mrb_nil_value(), 0` for each omitted optional
  keyword, unchanged). The generated-C++ diff is exactly 17 call-site
  lines and nothing else. No `#error`/coverage movement on its own: these
  were already-compiling methods with a real `g++` bug, not `#error`
  stubs.

- With that arity bug gone, `flat_map` is admitted into
  `BLOCK_FALLBACK_UPVAR_SAFE_METHODS`. It was already investigated and
  verified safe but held back purely by this measurement -- the one
  reachable call site, `RPG2k::Scene::Map#global_animation_targets`
  (`(-1..1).flat_map do |gy| (-1..1).map do |gx| ... end end`), has an
  inner block body that hit exactly the keyword bug above. Safety
  re-verified directly against the real vendored sources: this program
  reaches only `Enumerable#flat_map` (mruby-enum-ext `enum.rb:270`,
  `ary = []; self.each do |*e| e2 = block.call(*e) ... end; ary` --
  synchronous, per-element, never stored), never
  `Enumerator::Lazy#flat_map` (mruby-enum-lazy `lazy.rb:292`, which
  *does* store the block in a returned `Lazy` closure), because
  `build_config.rb` names every core gem explicitly with no gembox and
  lists `mruby-enum-ext` but not `mruby-enum-lazy`, so `Enumerator::Lazy`
  does not exist at runtime; a whole-program grep also found no other
  `def flat_map`/`alias ... flat_map`/`collect_concat`. Measured:
  compiled entry points **2286 -> 2287** (the one new method is
  `RPG2k__Scene__Map_global_animation_targets_impl`), methods compiled
  clean **2261 -> 2262**, left on the interpreter **32 -> 31**, total
  `#error` markers **50 -> 48** (-1 `BLOCK`, -1 `SENDB` -- exactly the
  one remaining pair that method had), BLOCK_FALLBACK block bodies
  **394 -> 396** (its outer and inner blocks). Coverage stays 98.6%
  (2262/2293). `g++ -fsyntax-only` still 0 errors with it added.

  `scripts/rpg2k_logic_check.rb` (1201), `scripts/rpg2k_scene_check.rb`
  (1062) and `scripts/lcf_testbed_check.rb` all pass with unchanged
  counts.
