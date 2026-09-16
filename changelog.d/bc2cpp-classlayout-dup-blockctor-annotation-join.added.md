- `tools/bc2cpp/bc2cpp.rb`'s `ClassLayout.analyze` (the whole-program
  ivar-class-hint prover backing devirtualized accessor/chained-accessor
  calls) gains three narrow, real-evidence-driven widenings, found by
  tracing every one of the 524 `CLASS_CANDIDATE` (poisoned-to-`UNKNOWN`)
  entries the whole-program diagnostic reported after the prior
  nil-tolerant-join round (`bc2cpp-niltolerant-classlayout-join.added.md`).

  Investigation first: of the 524, 508 (97%) are ivars whose real `SETIV`
  sites are *all* scalar-valued (Integer/Boolean/Symbol arithmetic --
  `LOADI_0`/`LOADFALSE`/`LOADTRUE`/`LOADSYM`/`ADDI`/`ADD`/... as the
  immediate producer, verified per-site with a temporary
  `ENV['BC2CPP_DEBUG_POISON']` probe on `ClassLayout.analyze`'s own SETIV
  loop, then removed). These were never real class-hint candidates in the
  first place -- `trace_new_target`/`proven_array_source_scan` have no
  (and should have no) opinion about a plain Integer/Boolean/Symbol write,
  so an ivar like `Game::Actor#@agi`/`@atk`/`@hp` (real stat fields,
  `IvarLayout`'s embedding domain, not this table's) is correctly and
  permanently out of `ClassLayout`'s scope; the diagnostic's own
  "poisoned to unknown (real evidence, but disagreeing/untraceable)"
  phrasing is technically accurate but this 97% majority is not a defect
  to chase. Of the remaining 16 ivars with at least one site that DOES
  resolve to a real class, most are genuine, correctly-poisoned gaps out
  of scope for a safe fix: real polymorphism (`Game::Character#@last_move_
  direction`, sometimes a literal Integer direction constant, sometimes a
  2-element `[dx, dy]` Array -- a real mixed-shape ivar), a class
  constructed through a dynamically-looked-up class object
  (`LCF::File#@root = klass.new(...)`, `klass` not a bare `GETCONST`
  chain), and an opaque incoming argument with no class annotation
  (`RGSS::Bitmap#@font`). Three real, narrow, fixable gaps remained:

  1. **`Klass.new(...) { block }` was invisible to `trace_new_target`.**
     Its own `case` only ever matched `SEND0`/`SEND` for a `.new` call,
     never `SENDB` -- so `Array.new(@base_raw.size) { |i| ... }`
     (mruby-array-ext's own documented block form of `Array#initialize`,
     a real, measured shape feeding `Game::Actor#@base`/`@equipment`/
     `@skills`) fell straight to "unresolvable" even though a block
     argument to `#initialize` never changes which class gets
     constructed. New `when 'SENDB'` arm, deliberately narrower than the
     `SEND0`/`SEND` arm it mirrors (only handles `name == 'new'`, and
     does not extend to `SSENDB` -- no real `self.new { ... }` call site
     exists in this program to vet).

  2. **A bare, argument-less `.dup` was invisible.** `mrb_obj_dup`
     (3rd/mruby @ 831da26b, `src/class.c`) always allocates a new object
     of the exact same class as its own receiver
     (`mrb_obj_alloc(mrb, mrb_type(obj), mrb_obj_class(mrb, obj))`),
     unconditionally, for any receiver -- bound as plain `Kernel#dup`
     (`src/kernel.c`'s own `MRB_MT_ENTRY(mrb_obj_dup, MRB_SYM(dup),
     MRB_ARGS_NONE())`) and never overridden anywhere in this program's
     own bytecode (grepped: no `def dup` in any closed-world mrblib
     file, and the new code re-checks that against the real
     whole-program registry the same way `core_array_return?` already
     re-validates a core name, so a future in-program override would
     just stop this branch from firing rather than keep trusting a
     now-false claim). New `elsif name == 'dup'` branch in the existing
     `SEND0`/`SEND` arm recurses into `trace_new_target` for the
     receiver's own class (identical recursion shape and termination
     argument as the pre-existing chained-accessor branch) and returns
     it directly -- this is what fully resolved `Game::Actor#@base`
     (`old_base = @base.dup; ...; @base = old_base` is a real site) and
     `#@skills` end to end once combined with fix 1 and fix 3 below.

  3. **The already-existing, already-sound `-> Array` magic-comment
     annotation mechanism was never threaded into `ClassLayout.analyze`
     at all.** `proven_array_source_scan` has accepted an `annotated`
     callback since the block recognizers started using it
     (`CodeGen#annotated_array_return`), but `ClassLayout.analyze`'s own
     call always passed nothing, so a self-call to a hand-annotated,
     bytecode-defined MONO method (a real gap this program actually
     has: `@equipment = normalize_equipment(...)`,
     `@base = base_stats(1)`, `@battle_commands =
     class_battle_commands`, all three confirmed by reading their own
     bodies to return an `Array` on every real path) stayed `UNKNOWN`
     here even though the exact same fact was already trusted a few
     opcodes away in the very same method body. `ClassLayout.analyze`
     now takes an optional 5th `annotated_array_return` callable,
     threaded straight through to `proven_array_source_scan`; the
     driver builds it from `Annotations.extract`'s own result (already
     computed earlier in the pipeline) with the identical MONO-keyed
     lookup `CodeGen#annotated_array_return` performs, duplicated rather
     than shared only because no `CodeGen` instance exists yet at this
     point in the driver. Three real `# bc2cpp: () -> Array` /
     `# bc2cpp: (fixnum) -> Array` annotations added to
     `mruby-rpg2k/mrblib/game.rb`'s `normalize_equipment`/`base_stats`/
     `class_battle_commands` (each verified MONO -- exactly one
     bytecode definition in the whole closed world -- and verified by
     reading their own source to return `Array` unconditionally) to
     actually exercise the newly-threaded mechanism.

  All three widenings keep the exact same soundness property every prior
  `ClassLayout` change has: this table is devirtualization-only, never
  struct-embedded (`IvarLayout` is the separate, untouched embedding
  analysis), and every real consumer of a `CLASS_HINT` re-verifies the
  fact with a live `mrb_class_ptr(...) == mrb_obj_class(M, elem)` check
  before taking a direct-call path, falling back to ordinary
  `mrb_funcall` otherwise -- so a wrong or overly-generous hint can only
  ever cost a missed optimization, never a wrong call.

  Also found, and deliberately NOT touched: `ClassLayout.analyze`'s own
  SETIV scan only walks each registered method's own top-level
  `irep.instructions`, never a nested block-body child irep (unlike
  `ArrayElementLayout.analyze`, which already walks `nested_block_labels`
  for exactly this reason). This is a real structural gap, but closing it
  cannot *reclaim* a poisoned ivar -- missing evidence only means
  `ClassLayout` poisons *less* than a fully-sound sweep would, never
  more, so a `@x = ...` write hiding inside a block body is a latent
  "this hint might occasionally be wrong for a block-only write" question
  (still runtime-guarded, still never a wrong call) rather than a source
  of today's 524. Left for a future, differently-scoped round if it turns
  out to matter.

  Verified via a real whole-program regen, isolated by diffing the exact
  `CLASS_HINT`/`CLASS_CANDIDATE` line sets before/after (not just counts):
  3 ivars gain a real class hint (`Game::Actor#@base` -> `Array`,
  `#@equipment` -> `Array`, `#@skills` -> `Array`), zero hints lost.
  `docs/bc2cpp_coverage.txt`: known-ivar-class hints (CLASS_HINT)
  251 -> 254, poisoned-to-unknown 524 -> 521. `known-array-element-class
  hints (ELEM_HINT)`'s own poisoned count moved 39 -> 42, the same kind of
  downstream `ArrayElementLayout`-now-sweeps-a-newly-Array-ivar
  consequence the prior nil-tolerant-join round already documented, not a
  regression (`ArrayElementLayout.analyze` only ever considers an ivar
  `ClassLayout` has already proven `Array`, so `@base`/`@equipment`/
  `@skills` were invisible to it entirely before this change). The three
  new `-> Array` annotations also let `compile_all` clean-compile 11 more
  real methods that previously hit a `SENDB`/`BLOCK` `#error` on one of
  these three call sites: compiled entry points 1965 -> 1979 (method-level
  coverage 85.1% -> 85.6%), `#error` total 864 -> 838. `bash
  scripts/bc2cpp_coverage_check.bash`: fresh. `scripts/rpg2k_logic_check.rb`
  (1201 checks), `scripts/rpg2k_scene_check.rb` (1062 checks), and
  `scripts/lcf_testbed_check.rb` all still pass. A real
  `SKIP_UNSUPPORTED=1` regen of the whole-program `.cpp`, `g++ -std=c++17
  -fsyntax-only` compiled against `3rd/mruby/include` + a real host build's
  own generated `include` (plus a `#include <mruby/numeric.h>` the known
  pre-existing `FIXABLE_FLOAT` gap needs), shows exactly the same 6
  pre-existing `int` -> `mrb_value` conversion errors this file's own
  prior rounds already documented, no new errors.
