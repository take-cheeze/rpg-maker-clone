- `tools/bc2cpp/bc2cpp.rb` can now statically resolve a module-level
  constant's own value to a proven Array/Hash/Range class, and feeds
  that fact into both the ivar `CLASS_HINT` prover (`ClassLayout.analyze`)
  and the block-inlining recognizers (`recognize_each_regions`,
  `recognize_collect_regions`, `recognize_accum_regions`,
  `recognize_sym_regions`, `recognize_range_each_regions`,
  `recognize_sort_regions`), which previously treated `GETCONST`/
  `GETMCNST` as evidence *only* while resolving a `.new` call's own
  receiver -- a bare or namespaced constant used as an ordinary receiver
  (`Game::Vehicle::TYPES.each { |type| ... }`, `STAT_NAMES.map { |k| ...
  }`) was structurally invisible to every one of these, however
  obviously Array/Hash-shaped it was.

  New pieces:
  - `build_registry` now also scans every class/module-body-level
    `SETCONST` site (the real shape a top-level `CONST = ...` compiles
    to) and records `container_constants`: real, fully-qualified
    constant name -> `'Array'`/`'Hash'`/`'Range'`, via a new
    `literal_container_class` helper recognizing the universal `CONST =
    [...].freeze` / `{...}.freeze` idiom this codebase's own constants
    overwhelmingly use (a literal `ARRAY`/`ARRAY2`/`HASH`/`RANGE_INC`/
    `RANGE_EXC` opcode, optionally followed by exactly one `.freeze`
    self-send reusing the same register -- confirmed real
    `Kernel#freeze` unconditionally `return self`, 3rd/mruby/src/
    kernel.c, and confirmed no real bytecode override of `#freeze`
    anywhere in this closed world could ever reach this narrow,
    adjacency-verified shape). Two disagreeing or unresolvable real
    sites for the same qualified name poison it to nil (dropped before
    the table is returned) -- never guessed.
  - `trace_new_target` gains a `container_constants:` keyword and a new
    non-`resolving_new` branch for `GETCONST`/`GETMCNST`: the exact same
    backward chain-assembly the `.new`-target case already used, just
    looked up in the new table instead of `DIRECT_CONSTRUCT_TARGETS`,
    including the same innermost-first lexical-nesting walk for a bare
    single-token reference. A new `HASH` literal terminal (mirroring the
    existing `ARRAY`/`ARRAY2`/`RANGE_INC`/`RANGE_EXC` cases) lets this
    also prove an ivar assigned a fresh hash literal directly.

  Verified via a real whole-program regen diff, isolated with `git
  stash`: compiled entry points 1956 -> 1963 (+7), method-level coverage
  84.7% -> 85.0%, `unhandled opcode BLOCK` 389 -> 380, `unhandled opcode
  SENDB` 366 -> 357 (9 real call sites newly inlined -- `Game::Vehicle::
  TYPES.each` in `RPG2k::Scene::Map#step_vehicle_routes`/`#draw_vehicles`
  /`#setup_sprites`, `RGSS::Audio.exist_with_ext`'s `EXTS`/
  `ENCRYPTED_EXTS.each`, and three `RPG2k::Scene::EquipMenu` methods
  iterating `STAT_NAMES`/`EQUIP_ORDER`). `known-ivar-class hints
  (CLASS_HINT)` 194 -> 251 (+57 -- larger than the block-inlining count
  alone, since `@ivar = SOME_ARRAY_CONST`-shaped SETIV sites benefit
  too). 99 real container constants resolved whole-program (spot-checked
  against real source: `Game::Interpreter::KEY_INPUT_CODES`/
  `KEY_INPUT_GROUPS`, `Game::Character::DIR_DELTA`/`TURN_LEFT`/
  `TURN_RIGHT`, ...). `bash scripts/bc2cpp_coverage_check.bash`: fresh.
  `scripts/rpg2k_logic_check.rb` (1201 checks), `scripts/
  rpg2k_scene_check.rb` (1062 checks), `scripts/lcf_testbed_check.rb`
  all still pass.
