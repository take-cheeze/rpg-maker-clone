- `tools/bc2cpp/bc2cpp.rb`'s `GETIDX`/`GETIDX0`/`SETIDX` codegen (`arr[i]`,
  `arr[i] = v`) now skips its own runtime Array/Hash/String receiver-type
  gate at a call site where the receiver is ALREADY statically provable --
  reusing, unchanged, the exact same whole-program facts
  `recognize_each_regions`/`recognize_hash_each_regions` already trust for
  the identical question at a `.each`/`.map`/... call site
  (`trace_new_target`'s own fresh-`.new`/GETIV-CLASS_HINT/argument-
  annotation/chained-accessor chase, plus `proven_array_source`'s own
  ARRAY-literal/core-Array-return-method chase for the Array case). New
  helper `static_indexable_class`, no new tracing logic -- just a new call
  site for logic this file already ships and relies on elsewhere.

  A proven Array receiver still keeps the `mrb_integer_p` index-type
  check (a Range/other index still needs the real `[]`/`[]=` send --
  `bc2cpp_ary_entry`/`mrb_ary_set` only ever handle a fixnum index) but
  drops the receiver-type branch itself down to one `mrb_raise`-on-
  mismatch guard. A proven Hash receiver drops ALL branching -- `[]`
  becomes a single unconditional `mrb_hash_get`, `[]=` a single
  unconditional `mrb_hash_set` (Hash's own `[]`/`[]=` already accept any
  key type, no index-type check needed at all). The `mrb_raise` on a
  mismatch is deliberate defense in depth against a wrong trace (the same
  "trust the proof to pick the fast path, still verify at runtime" shape
  `emit_each_inline`'s own `#each` receiver check already established),
  never a silent wrong answer -- and every call site whose receiver isn't
  statically provable keeps the exact same four-way runtime-checked
  fallback as before, byte for byte, so this can only ever remove
  branches, never change behavior for the traced-nil case.

  Motivated by the real whole-program diagnostic's own "top dynamically-
  dispatched method name" stat, which was almost entirely misleading for
  `:[]`: of the top-ranked 2088 textual `mrb_funcall(..., "[]", ...)`
  occurrences, 2073 (99.3%) turned out to already be this exact guarded
  fallback branch -- not naive dispatch, just the "receiver isn't
  Array/Hash/String" arm of an already-existing fast path. Assuming Array
  from the index type alone (rather than checking the receiver) would have
  been unsound: this codebase has real classes (`Game::Switches#[]`/
  `Game::Variables#[]`, `mruby-rpg2k/mrblib/game.rb:1430,1495`) that take a
  fixnum id and do something else entirely (a Hash-backed lookup with a
  default) -- assuming Array unconditionally would call `bc2cpp_ary_entry`
  (real `RArray*` internals) on a non-Array object.

  Verified against the real whole-program diagnostic (compile coverage
  unaffected, as expected -- this changes only already-compiling code's
  own shape, not what compiles): `:[]` dispatch-text occurrences 2088 ->
  1641, `:[]=` 484 -> 279, total `mrb_funcall`/`mrb_funcall_with_block`
  call sites 14206 -> 13554. `scripts/rpg2k_logic_check.rb` (1201 checks),
  `scripts/rpg2k_scene_check.rb` (1062 checks), and
  `scripts/lcf_testbed_check.rb` all still pass unchanged. Directly
  inspected real generated output: `Game::Party#actors[actor_index]`
  (Array-proven via `Game::Party#@actors`'s own CLASS_HINT) and a real
  `Hash`-proven `SETIDX` site, both collapsing to the expected single
  guarded fast path -- 764 real call sites across the whole program take
  this new path. A real `g++ -std=c++17 -fsyntax-only` compile of the
  actual `SKIP_UNSUPPORTED=1` generated output confirms the exact same 17
  pre-existing, already-documented, unrelated errors as immediately before
  this change (only their line numbers shifted) and zero new ones.
