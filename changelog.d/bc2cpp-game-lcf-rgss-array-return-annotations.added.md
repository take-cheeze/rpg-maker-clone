- Investigated all ~27 `Game::*`/`LCF::*`/`RGSS::*`-owned entries the
  whole-program `== annotation candidates (opaque incoming argument,
  unresolved) ==` diagnostic (`tools/bc2cpp/bc2cpp.rb`'s
  `report_annotation_candidates`) reports, by tracing every real call site
  in `.rb` source (not just the file the candidate's own owner lives in).
  Finding: every one of them is already correctly handled by prior rounds
  -- none needed a new argument-position annotation. Three shapes explain
  the whole set: (1) a real object-typed ivar (`Game::EnemyAi#@db` ->
  `LCF::Database`, `#@state` -> `Game::State`, `Game::Shop#@db`/`@party`,
  `Game::State#@party`, `Game::Interpreter#@state`, ...) already carries a
  `ClassAnnotations` token (`# bc2cpp: (LCF::Database, Game::State)` etc.)
  that resolves its own `CLASS_HINT`, but `report_annotation_candidates`
  only ever consults the separate, scalar-only `Annotations` reader (its
  own `already_at` lambda never checks `class_annotations`), so an
  object-typed ivar structurally can never leave this list no matter how
  completely it is annotated -- confirmed by reading the function itself,
  not assumed; (2) a String/Hash/Boolean/native-IO argument (`Game::Shop#@
  allow_buy`/`@allow_sell`, `Game::Actor#@charset_name`, `Game::State#@
  parallax`/`@system_graphic`, `Game::Timer#@visible` -- confirmed boolean
  via its own real call site, `t.start(cmd.param(3) != 0, cmd.param(4) !=
  0)`, `mruby-rpg2k/mrblib/interpreter.rb` -- `RGSS::Bitmap::LoadError#@
  path`/`@reason`, `RGSS::ErrorReport::Tee#@io`) has no representable
  `Annotations`/`ClassAnnotations` token at all (`String`/`Hash`/`IO` are
  never real `known_owner`s in this closed world, and there is no boolean
  token), already honestly documented inert at each site (`# bc2cpp:
  (String, String)`, `# bc2cpp: (, Hash)`, ...); and (3) `LCF::Tree#@maps`
  is a real `Array` (confirmed at both real construction sites,
  `mruby-lcf/mrblib/lcf.rb`'s `read_section`/`to_rb` `:Tree` arms, each
  building it as `Array.new(map_count) { read_ber s }` / a `read_ber`-only
  push loop) that is deliberately left unannotated: it is exactly the
  live SETIV-embedding-candidate shape this file's own history already
  flags as the real `Array`-argument-position `KeyError: key not found:
  :array` landmine (`native_arg_types` has no `:array` case), so
  annotating it would crash a real regen rather than help one -- verified
  this stays correctly unannotated, not merely inherited. Also re-verified
  the two previously-known genuine-polymorphism exclusions still hold:
  `Game::Screen#approach`'s `cur`/`step` (Integer-or-Float, per
  `tools/bc2cpp/bc2cpp.rb`'s own citation of the `@pan_x`/`@pan_y`
  subpixel-Float accumulator) and `RPG2k::Scene::ItemMenu#enter_target_
  confirm` (Symbol-or-nil, out of this round's own scope: a `Scene`-owned
  candidate).

  Separately, 16 new `# bc2cpp: (...) -> Array` return-class annotations
  (`mruby-rpg2k/mrblib/game.rb` x8, `mruby-rpg2k/mrblib/game/battle_
  support.rb` x7, `mruby-lcf/mrblib/lcf.rb` x1 -- `Game::Actor#cursed_
  armor_state_ids` widens an existing `(fixnum)` argument annotation
  rather than adding a new one), each a real, MONO (single-definition,
  whole-program-registry-confirmed), body-read proof that every real
  return path is a fresh Array literal, never `nil`: `Game::Actor#learn_
  table`/`#cursed_armor_state_ids`/`#permanent_states`/`#defensive_
  attribute_ids`/`#weapon_attributes`, `Game::Party#item_state_ids`/
  `#skill_targets`/`#skill_state_ids`/`#battle_skills`/`#battle_items`,
  `Game::Troop#live_members` (private)/`#drops`, `Game::Interpreter#take_
  revealed_monsters`/`#take_fled_monsters`/`#take_monster_kills`, and
  `LCF#unpack_int32`. Most are
  called bare (self-implicit) elsewhere in the very same class/module
  (e.g. `Game::Actor#adjust_equipment_states`' own `cursed_armor_state_
  ids(item_id).each { ... }`, `Game::Party#skill_effective?`/`#cast_
  skill`'s own `skill_targets(sk, caster, target).any?`/`.each`,
  `LCF#to_rb`'s own `:int32_array` arm, `unpack_int32(d)`), the exact
  pattern the prior `ClassLayout`-widening round's own three examples
  (`normalize_equipment`/`base_stats`/`class_battle_commands`) exercised;
  a few (`Game::Actor#weapon_attributes`, `Game::Party#battle_skills`/
  `#battle_items`, `Game::Interpreter#take_*`) have no bare self-call in
  their own class but are annotated anyway since the claim is a plain,
  unconditional property of the body itself, matching this file's own
  "go on annotating rpg2k for readability" precedent -- soundness is
  identical either way (the annotation only ever unlocks a chained-Array
  block-compile path or a `ClassLayout` self-call proof, always behind a
  runtime `mrb_array_p` tripwire).

  Verified via a real whole-program regen: `magic-comment return
  annotations (ANNOTATED)` 140 -> 155 (15 new + 1 widened), `annotation
  candidates (opaque argument, unresolved)` unchanged at 43 (expected --
  see the investigation above), `CLASS_HINT`/`CLASS_CANDIDATE`/`ELEM_HINT`
  all unchanged (none of the 16 newly-annotated calls feeds a same-class
  SETIV). The newly-provable chained-Array block sites let `compile_all`
  clean-compile 3 more real methods: compiled entry points 1981 -> 1984
  (method-level coverage 85.7% -> 85.8%), `#error` total 828 -> 818 (`
  unhandled opcode BLOCK` 348 -> 343, `unhandled opcode SENDB` 325 -> 320).
  `bash scripts/bc2cpp_coverage_check.bash`: fresh. `scripts/rpg2k_logic_
  check.rb` (1201 checks), `scripts/rpg2k_scene_check.rb` (1062 checks),
  and `scripts/lcf_testbed_check.rb` all still pass. A real
  `SKIP_UNSUPPORTED=1` regen, `g++ -std=c++17 -fsyntax-only` compiled
  against a real host build's own generated `include` (plus `#include
  <mruby/numeric.h>`), shows exactly the same 6 pre-existing `int` ->
  `mrb_value` conversion errors this file's own prior rounds already
  documented, no new errors.
