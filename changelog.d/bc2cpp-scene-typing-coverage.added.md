- One real `# bc2cpp: (...) -> Array` magic-comment return annotation added
  to `RPG2k::Scene::Menu#build_commands` (`mruby-rpg2k/mrblib/scene/menu.rb`)
  -- a private, `MONO` (single-def, program-wide) helper called exactly once,
  self-implicit, from `#build_windows`' own `@commands = build_commands`.
  Read in full: every real path through its body (the `db.rpg2003?` branch's
  `ids.filter_map { ... } << RPG2K_COMMAND_KEYS.last`, and the plain branch's
  bare `RPG2K_COMMAND_KEYS`, a real Array constant) always feeds into the
  method's own final, unconditional `keys.map { ... }` -- so the method
  itself always returns a fresh Array, on every real code path, exactly the
  shape `ClassLayout.analyze`'s recently-added `annotated_array_return`
  threading (see `tools/bc2cpp/bc2cpp.rb`'s own `ANNOTATED_ARRAY_RETURN_
  THREADING` comment) was built to catch -- the same pattern a prior round
  used for `Game::Actor#normalize_equipment`/`#base_stats`/
  `#class_battle_commands` (`mruby-rpg2k/mrblib/game.rb`). Verified with a
  real, isolated diff (not just before/after counts): `RPG2k::Scene::Menu#
  @commands` moves from `CLASS_CANDIDATE` (poisoned to unknown) to a real
  `CLASS_HINT (Array)`, with zero other lines changed, before adding it for
  real.

  A full re-investigation of the whole-program diagnostic's own `==
  annotation candidates (opaque incoming argument, unresolved) ==` section
  found every real `RPG2k::Scene::*` entry already correctly annotated from
  an earlier round (`RPG2k::Scene::Base#initialize`'s `parent`,
  `MapWorld`/`VehicleWorld#initialize`'s `scene`/`rng`, `Battle#initialize`'s
  `map`/`owner`, and `DebugMenu`/`ItemMenu`/`Menu`/`Order`/`SaveLoad#
  initialize`'s `state` -- all real `ClassAnnotations` class-name tokens,
  confirmed live against the real `== known-ivar-class hints ==` section,
  each already showing a resolved `CLASS_HINT`) -- they only still print as
  `CANDIDATE` because `report_annotation_candidates` checks the narrower
  fixnum/symbol/array `Annotations` reader, not `ClassAnnotations`, so a
  real class-name annotation never clears that specific list. `Battle#
  initialize`'s `req` (a `Hash`, never a real `known_owner` in this closed
  world) is correctly left unannotated -- no mechanism models it. The two
  already-known `play_sound`/`enter_target_confirm` exclusions from the
  prior round were re-verified still correct (the diagnostic's "used in EQ"
  heuristic is still a `String#==` false positive; `enter_target_confirm`'s
  argument is still Symbol-or-nil, not always Symbol).

  A wider read across every `.rb` file under `mruby-rpg2k/mrblib/scene/`
  for a self-called `MONO` helper unconditionally returning one class (the
  `normalize_equipment`/`base_stats` pattern) turned up several near
  misses, each deliberately left un-annotated for a real, checked reason:
  `RPG2k::Scene::Battle#battle_commands` is `POLY` (also defined on
  `Game::Actor`), so `annotated_array_return`'s own name-keyed `MONO` gate
  would never even consult an annotation placed on it; `RPG2k::Scene::
  StatusMenu#new_window` (always `Window.new(...)`) and `#windows` (`->
  Array<RPG2k::Window>`, confirmed real evidence) were both annotated and
  measured live -- neither moves a single `CLASS_HINT`/`ELEM_HINT` line,
  because a bare `-> Klass` return annotation is deliberately not wired
  into `trace_new_target` (only into `ArrayElementLayout`'s own element
  value tracer, per that class's own comment), so reverted rather than
  shipping an inert annotation; `RPG2k::Scene::Battle#battle_option_rows`/
  `#candidate_troops`/`RPG2k::Scene::Map#troop_ids` are all real,
  provably-Array `MONO` methods but are only ever consumed into local
  variables, never a `SETIV`, at every real call site, so there is no ivar
  for an annotation to unblock.

  Verified via a real whole-program regen (not just confirmed unchanged):
  `docs/bc2cpp_coverage.txt` -- known-ivar-class hints (`CLASS_HINT`)
  254 -> 255, poisoned to unknown 521 -> 520, magic-comment return
  annotations (`ANNOTATED`) 140 -> 141, compiled entry points 1981 -> 1982
  (methods compiled clean 1965 -> 1966, `#error` total 828 -> 826).
  `bash scripts/bc2cpp_coverage_check.bash` reports fresh. `scripts/
  rpg2k_logic_check.rb` (1201 checks), `scripts/rpg2k_scene_check.rb`
  (1062 checks), and `scripts/lcf_testbed_check.rb` all still pass. A real
  `SKIP_UNSUPPORTED=1` whole-program regen, `g++ -std=c++17 -fsyntax-only`
  compiled, shows exactly the same 6 pre-existing `int` -> `mrb_value`
  conversion errors already documented elsewhere, no new errors.
