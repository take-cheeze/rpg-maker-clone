- `tools/bc2cpp/bc2cpp.rb` can now devirtualize a genuinely POLY (multiply-
  defined) method name, not just MONO/TYPED ones. Real C++ virtual dispatch
  (a vtable per compiled class) was considered first and rejected: every
  mruby object stays an opaque, tagged `mrb_value` (`RObject`/`RData`) --
  giving compiled classes real vtables would mean growing a second, GC-
  managed object model alongside mruby's own, far past this file's
  established scope of compiling individual leaf method bodies against the
  real mruby object model. Instead, `compile_poly_small_n` chains the same
  runtime-guarded-direct-call trust model TYPED/IVAR_ACCESSOR already use
  (`mrb_class_ptr(<owner>) == mrb_obj_class(M, recv)`) across every real,
  compile-clean, pure-mandatory, exact-arity owner of a POLY name, in a
  bounded `if`/`else if`/... chain, falling back to ordinary `mrb_funcall`
  only for a receiver matching none of them -- gated at a small owner count
  (`POLY_SMALL_N_MAX = 5`) measured against real whole-program fan-out
  first (`width` has 5 owners, `term`/`party`/`size`/`repeat?`/`db` have
  2-3, `dispose` has 16 and stays ungated), since past that point a linear
  chain of runtime class checks stops being clearly cheaper than mruby's
  own method-table hash lookup and the code-size cost keeps growing.
  Deliberately narrower than TYPED/MONO in two ways so it stays reviewable
  independent of the existing optional-arg-/`NATIVE_ARG_TARGETS`-aware
  `call_argv` machinery: only pure-mandatory-arity candidates join the
  chain, and only when a candidate's own arity exactly matches the call
  site's real `n` -- anything that doesn't fit either way simply never
  joins, always safe (it still gets the correct answer through the same
  `mrb_funcall` fallback a receiver of some other, unlisted class already
  goes through today).

  Two real bugs surfaced and got fixed along the way, both root-caused
  rather than defensively worked around:

  1. A `.singleton`-suffixed owner (bc2cpp's own naming for `def self.foo`/
     `class << self` methods, e.g. `"Game.singleton"`) can never actually
     match the chain's own runtime guard: `mrb_obj_class(M, recv)` is
     `mrb_class_real(mrb_class(mrb, obj))` (confirmed by reading
     `3rd/mruby/src/class.c` directly), which walks PAST
     `MRB_TT_SCLASS`/`MRB_TT_ICLASS` wrappers via `cl->super` and returns
     the real underlying class (e.g. plain `Module`) for a module/class
     object with its own singleton methods -- never that object's own
     identity. Left in, such a candidate would silently never fire (not a
     wrong answer -- the chain falls through to the next candidate or the
     `mrb_funcall` fallback either way), just dead code generation
     miscategorized as "runtime-class-checked". `poly_small_n_targets`
     now excludes any `.singleton`-suffixed owner from candidate selection
     up front.
  2. `IvarLayout.trace_type`'s incoming-argument fallback blindly trusted
     ANY magic-comment argument annotation token as an embeddable ivar
     type, even though only `:fixnum`/`:symbol` are real embeddable types
     (`CodeGen::TYPE_OPS` has no `:array`/etc. entry, and the
     `Annotations` class's own header comment already documented this
     restriction -- it was just never enforced at this call site). An
     `Array`-annotated argument (`@x = x` seeded from an `Array`-tagged
     parameter) could poison an ivar's inferred embed type, crashing far
     downstream with a raw `KeyError: key not found: :array` inside
     GETIV/SETIV codegen for a totally unrelated owner. Pre-existing and
     dormant -- only ever surfaced because this feature's broader
     `compiles_clean?` probing was the first code path to ever reach that
     specific irep label. Fixed at the root (restrict the fallback to
     `:fixnum`/`:symbol`) rather than rescuing the exception where it
     happened to surface, matching this file's own "fail loud, never
     silently guess wrong" discipline. Also corrected the `Annotations`
     class's own header comment, which had claimed `native_arg_types` was
     the sole consumer of `args` -- it wasn't.

  Verified against the real whole-program diagnostic
  (`docs/bc2cpp_coverage.txt`, regenerated for real via
  `MRBC=path/to/host/mrbc ruby scripts/bc2cpp_coverage_report.rb`):
  `POLY-marked (receiver's runtime class genuinely decides)` drops from
  5802 to 5176 real dispatch sites (626 real sites converted to
  `POLY_SMALL_N` chains after excluding `.singleton` owners -- an earlier,
  pre-`.singleton`-exclusion measurement briefly saw 739, all correctly
  taken back out once the dead-branch bug above was fixed and those sites'
  candidate counts dropped below 2 or lost a chain slot). `ivar embedding
  (EMBED)` drops from 110 to 108 (the two real embeddings the
  `IvarLayout.trace_type` fix correctly stops trusting). Total
  `mrb_funcall`/`mrb_funcall_with_block` call sites stays exactly 12757
  (every `POLY_SMALL_N` site still keeps exactly one fallback `mrb_funcall`
  line, just reclassified out of the `// POLY :` regex bucket this report
  script counts). Directly inspected real generated output for the real
  `mruby-rpg2k-compiled` gem (510 real `POLY_SMALL_N` sites emitted, e.g.
  `:dead?  -> Game::Battle::Combatant, Game::Enemy, Game::Actor`,
  `:refresh -> RPG2k::Scene::ChipsetEditor, RPG2k::Scene::DebugMenu,
  RPG2k::Scene::MapViewer, RPG2k::Scene::StatusMenu`): zero `.singleton`
  owners appear in any emitted chain, and `:clamp` (which had a
  `Game.singleton`/`RPG2k::Scene::MapViewer` chain before the fix) now
  correctly falls back to plain `// POLY :clamp -- real dynamic dispatch`
  at every call site, since excluding its `.singleton` candidate drops it
  below the 2-candidate minimum. `scripts/rpg2k_logic_check.rb` (1201
  checks), `scripts/rpg2k_scene_check.rb` (1062 checks), and
  `scripts/lcf_testbed_check.rb` all still pass unchanged.
