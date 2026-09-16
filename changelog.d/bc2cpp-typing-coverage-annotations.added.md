- Five real `# bc2cpp: (...)` magic-comment type annotations added across
  `mruby-rpg2k`/`mruby-lcf` mrblib, resolving 5 of the 48 real "annotation
  candidates" `tools/bc2cpp/bc2cpp.rb`'s own whole-program diagnostic
  flags (opaque `#initialize`/method arguments stored straight to an
  ivar or used in an arithmetic/comparison opcode, with no already-known
  type -- see `report_annotation_candidates`'s own comment):

  - `LCF::Tree#initialize`'s `selected_id` (`# bc2cpp: (fixnum)`) -- both
    real construction sites (`lcf.rb:251`/`293`) pass `read_ber`'s own
    result, which always raises rather than returning anything but a
    real Integer.
  - `Game::ChipSet#initialize`'s `id` (`# bc2cpp: (, fixnum)`) -- used
    directly in a `>` comparison (`id && id > 0`), and every real `.new`
    site passes a real liblcf integer id.
  - `Game::Actor#set_charset`'s `index` (updated `(String, )` ->
    `(String, fixnum)`) -- all 3 real call sites resolve to Integer
    (`cmd.param(1)`, `sa.sprite_id || 0`, `m[:charset_index] ||
    actor.charset_index`, the last bottoming out at a real liblcf
    integer field).
  - `Game::Actor#weapon_crit_chance`'s `bonus` (`# bc2cpp: (fixnum)`) --
    both real callers (`#crit_chance`'s `weapon_crit_bonus`, and a
    battle-support Hash literal's own `it.critical_hit || 0`) are always
    Integer.
  - `Game::Actor#set_class_id`'s `id` (`# bc2cpp: (fixnum)`) -- all 3
    real call chains traced to Integer, never nil, including through
    `@class_id`'s own always-Integer invariant (`id && id > 0 ? id : 0`)
    and `LCF::EventCommand#param`'s own `|| 0` fallback.

  A real, live-caught trap along the way: two more candidates
  (`LCF::Tree#@maps`, `LCF::EventCommand#@parameters`) are genuinely
  always real Arrays at their own real construction sites, and `Array`
  is a real, already-used `ClassAnnotations` token elsewhere in this
  codebase (`Game::Battle#initialize`'s own `(Array, Array)`) -- but
  adding it to either of THESE two positions crashes the whole compiler
  for real: `Annotations::TYPES` also maps `'Array' => :array` for the
  SAME comment token, and unlike the *return*-position `-> Array` (which
  only ever feeds a block-receiver return-type gate), an `Array` token
  in *argument* position also reaches `native_arg_types`' own struct-
  field codegen for any argument whose ivar is a live SETIV-embedding
  candidate -- which both of these are, being exactly the shape
  `report_annotation_candidates` found them by. `native_arg_types` has
  no `:array` case, so this raised a real, uncaught `KeyError` mid-
  compile, caught only by actually re-running the real whole-program
  diagnostic before committing (not just `ruby -c`). Reverted both;
  `Array` in argument position stays safe only for ivars that are never
  SETIV-embedding candidates in the first place.

  Also investigated and deliberately left un-annotated, each for a real,
  cited reason (would be a genuinely dishonest or unsafe claim, not just
  unhelpful): `Game::Screen#approach`'s `cur`/`step` (legitimately
  Integer-or-Float, not fixnum -- `@pan_step` is a real Float whenever a
  fractional pan speed is in effect); `RPG2k::Scene::MapWorld`/
  `VehicleWorld#play_sound`'s first argument (the diagnostic's own "used
  in EQ" heuristic is a false positive here -- the real comparison is
  `String#==`, not integer equality; already correctly annotated
  `String`); `RPG2k::Scene::ItemMenu#enter_target_confirm`'s argument
  (Symbol-or-nil, not always Symbol -- one real, reachable call site
  passes `nil`, which would raise `mrb_symbol_p`'s own real `TypeError`
  guard the first time that code path ran, if this ivar ever became
  embed-eligible). 21 more of the 48 turned out to already carry a
  correct `ClassAnnotations` (class-name) annotation and simply aren't
  reachable through `report_annotation_candidates`'s own narrower
  fixnum/symbol-only scan -- no change needed for those.

  Verified via a real whole-program regen diff: `docs/bc2cpp_coverage.txt`
  regenerated for real (not just confirmed unchanged) -- annotation
  candidates 48 -> 43, ivar embedding (EMBED) 109 -> 110, compiled entry
  points 1947 -> 1948, classes needing `MRB_SET_INSTANCE_TT` 11 -> 12.
  `scripts/rpg2k_logic_check.rb` (1201 checks), `scripts/
  rpg2k_scene_check.rb` (1062 checks), and `scripts/lcf_testbed_check.rb`
  all still pass.
