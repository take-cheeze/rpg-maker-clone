- `tools/bc2cpp/bc2cpp.rb`'s `ClassLayout.analyze` (the whole-program
  ivar-class-hint prover backing devirtualized accessor/chained-accessor
  calls) no longer treats a plain `@x = nil` `SETIV` site as evidence that
  disagrees with a real class written elsewhere. Previously any two real
  `SETIV` sites whose traced classes didn't match -- including a nil
  literal, which traced to `nil` (unresolvable) the same as any other
  opaque write -- permanently poisoned the ivar to `UNKNOWN`, so the
  extremely common "init to `nil`, assign a real object once it's needed"
  idiom (`@battle_request`, `@transition`, a lazily-created `Window`, ...)
  could never earn a class hint at all, no matter how uniform the real
  assignment sites were.

  New `nil_literal_write?(irep, idx, reg)` helper (mirrors
  `trace_eqq_literal_receiver`'s own defensive MOVE-chain-following
  backward scan) recognizes the real bytecode shape a `@x = nil` literal
  compiles to (`LOADNIL Rn` immediately feeding `SETIV @x Rn`, confirmed
  against `mrbc`'s own disassembly) and `ClassLayout.analyze`'s own SETIV
  loop now skips such a site entirely -- neither agreeing nor disagreeing
  evidence -- rather than folding it into the existing "found ||= UNKNOWN"
  path. An ivar that is *only ever* nil-written anywhere in the closed
  world now simply never earns an entry (there's no class to hint at,
  and reporting `UNKNOWN` for it would be noise, not an actionable
  candidate); an ivar written to both nil and a single, uniform real
  class earns that class's hint, exactly as if the nil-writing sites
  didn't exist.

  Deliberately narrow and safe by construction, not merely by testing:
  this table is devirtualization-only, never struct-embedded (that's
  `IvarLayout`'s separate analysis, untouched by this change -- a raw
  C++ struct field genuinely has no room for "or nil" the way this
  runtime-guarded hint does), and every real consumer of a `CLASS_HINT`
  already re-verifies the fact with a live `mrb_class_ptr(...) ==
  mrb_obj_class(M, elem)` check before taking a direct-call path, falling
  back to ordinary `mrb_funcall` otherwise (`compile_send`'s own
  TYPED/`IVAR_ACCESSOR_DEVIRT` branches). So an ivar that's genuinely
  nilable at runtime, not just at construction, is still handled
  correctly at every real call site: the guard simply fails on the nil
  path, the same cost as any other guard miss, never a wrong call.

  Verified via a real whole-program regen diff, isolated with `git
  stash` to compare the exact `CLASS_HINT` line sets before/after: 34
  ivars gain a real class hint (`Game::Interpreter#@battle_request` ->
  `BattleRequest`, `#@inn_request` -> `InnRequest`,
  `Game::Screen#@transition` -> `Game::Transition`,
  `RPG2k::Scene::ItemMenu#@item_window`/`@desc_window`/`@target_window`
  -> `Window`, `RPG2k::Scene::Map#@event_menu`/`@event_save_load`/
  `@inn_interp` -> `Game::Interpreter`, ... -- all real lazy-init-to-nil
  fields), zero hints lost. `docs/bc2cpp_coverage.txt`: known-ivar-class
  hints (CLASS_HINT) 160 -> 194, poisoned-to-unknown 643 -> 581 (the
  remaining gap between +34 and -62 is ivars that were *only* ever
  nil-written anywhere in the program, which now simply drop out of both
  buckets rather than staying poisoned). `known-array-element-class
  hints (ELEM_HINT)`'s own poisoned count moved 33 -> 39, a downstream
  consequence of `ArrayElementLayout` now sweeping some newly-Array-typed
  ivars for the first time, not a regression. `bash scripts/
  bc2cpp_coverage_check.bash`: fresh. `scripts/rpg2k_logic_check.rb`
  (1201 checks), `scripts/rpg2k_scene_check.rb` (1062 checks), and
  `scripts/lcf_testbed_check.rb` all still pass.
