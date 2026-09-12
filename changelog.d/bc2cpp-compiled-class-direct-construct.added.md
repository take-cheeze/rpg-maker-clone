- `tools/bc2cpp/bc2cpp.rb` generalizes its existing "MONO :new -> direct
  native construct" mechanism (`NATIVE_CONSTRUCT_TARGETS`, hand-written
  native RGSS classes backed by `DataType<T>`) to ordinary bc2cpp-COMPILED
  Ruby classes (`DIRECT_CONSTRUCT_TARGETS`): a monomorphic
  `SomeClass.new(args)` call site, proven via `trace_new_target`'s existing
  `resolving_new:` mode, skips `Class#new`'s own allocate+initialize
  dispatch chain and calls a new generic `bc2cpp_direct_alloc` helper
  (`mrb_obj_alloc(M, MRB_INSTANCE_TT(c), c)` -- correct for any instance
  type, including an embedded `MRB_TT_DATA` struct) followed directly by
  the target's own already-compiled `#initialize_impl`, discarding its
  return value (real Ruby `.new` always returns the new object, never
  whatever `#initialize` itself returns). No hand-written native
  constructor is needed per class, unlike Rect/Color/Tone: a compiled
  class's own `#initialize` is already an ordinary `_impl` function.
  Guarded the same way as the native path (a runtime `mrb_class_ptr(recv)
  == <owner>_compiled_class()` check against a durable `RClass*` captured
  at gem-init, falling back to `mrb_funcall` on a mismatch), and only after
  confirming, live against the real whole-program registry, that the
  target owner has no custom `self.new`/`self.allocate` and that
  `#initialize` is a genuine, compiling, pure-mandatory-arity leaf whose
  arity matches the call site.
  `mruby-rpg2k-compiled/src/register.cxx` gains the matching
  `g_direct_construct_*`/`*_compiled_class()` pair for two real,
  confirmed-firing targets: `Game::Transition` (`Game::Screen#fade_to`) and
  `Game::Map` (`RPG2k#load_map`). Three more classes were seriously
  considered and ruled out for three different, real reasons, each
  documented in `DIRECT_CONSTRUCT_TARGETS`' own comment: `Game::Screen`'s
  one real call site is a bare, non-namespace-qualified constant reference
  `trace_new_target` cannot resolve; `Game::State`'s one real call site
  sits inside a Ruby block (permanently out of this compiler's scope);
  `Game::EnemyAi`/`Game::ChipSet`'s real call sites each sit inside a
  method that never compiles at all for an unrelated reason (`super`/
  `rescue`), so SKIP_UNSUPPORTED drops the whole enclosing function and the
  devirtualization never reaches the final output -- confirmed only by
  regenerating the real `SKIP_UNSUPPORTED=1` build and grepping it, not by
  reasoning about the Ruby source alone.
  Added `mruby-rpg2k/test/test.rb` (this gem's first test file): 200
  `Game::Transition.new`/150 `Game::Map.new` instances, a real `GC.start`,
  and per-instance mutation confirming no aliasing, matching the style of
  `mruby-rgss/test/test.rb`'s own Sprite tone/color/rect test for
  `NATIVE_CONSTRUCT_TARGETS`. Verified: a real regenerated
  `rpg2k_compiled_gen.cpp` diffs byte-identical to an unmodified-bc2cpp.rb
  build except for the two new devirtualized call sites (fallback branch
  included); the full host `mrbtest` suite (RPGMAKER_BC2CPP=1 and without)
  both pass 1891/1900 OK, 0 KO, 0 crashes; `valgrind --leak-check=full`
  reports zero errors and zero leaks.
