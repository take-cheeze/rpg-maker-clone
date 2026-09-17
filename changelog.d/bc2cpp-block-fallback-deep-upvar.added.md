- `tools/bc2cpp/bc2cpp.rb`'s `BLOCK_FALLBACK` mechanism can now compile a
  block whose own nested block reaches past its immediate parent into the
  ENCLOSING METHOD's locals -- `out = []; 2.times do |j| 2.times do |i|
  ... quarters[j][i] ... out << ... end end`, this program's own
  `Game::ChipsetLayout.quads_from_quarters`, and the like. A real
  whole-program sweep found this single cause behind the ENTIRE remaining
  `BLOCK`/`SENDB` bucket: all 33 still-declined call sites named an
  ALREADY-allowlisted receiver (`each`, `map`, `times`, `each_with_index`,
  `each_index`), and every one was refused by `collect_block_upvars`'
  depth-0-only rule alone -- zero were allowlist misses, splat/keyword call
  sites, arity mismatches or register-layout mismatches.

  Real `mrbc -v` disassembly of that shape shows exactly what was needed
  and why index alone could not carry it:

        irep (method)   nlocals=4   R1:quarters  R3:out
          BLOCK R5 I[0] / SENDB R4 :times n=0
        irep (block |j|)              -- contains NO GETUPVAR at all
          BLOCK R4 I[0] / SENDB R3 :times n=0
        irep (block |i|)
          GETUPVAR R5  1  1     ; level 1, index 1 -- the METHOD's `quarters`
          GETUPVAR R6  1  0     ; level 0, index 1 -- the BLOCK's  `j`
          GETUPVAR R5  3  1     ; level 1, index 3 -- the METHOD's `out`

  The same index `1` names two different variables at two levels in one
  block, so captured pointers are now keyed by the real `(level, index)`
  pair (`upvar_var_name`); level 0 deliberately keeps its original
  un-suffixed spelling, so all 330 already-shipping level-0-only bodies
  generate byte-for-byte identical C++. `block_upvar_needs` replaces
  `collect_block_upvars` at the gate and propagates transitively: a child's
  `[l, x]` for `l >= 1` becomes this irep's `[l - 1, x]`, which is what
  makes the outer `|j|` block capture `quarters`/`out` at all despite never
  mentioning them. `emit_rproc_construction` boxes `&r<idx>` for a level-0
  entry as before and FORWARDS the already-held pointer
  (`upvar_var_name(l - 1, idx)`, no `&` -- that would box a
  pointer-to-pointer) for a deeper one.

  Soundness needed no new argument. The pointer is still only ever
  forwarded through frames the existing `BLOCK_FALLBACK_UPVAR_SAFE_METHODS`
  allowlist has already proven invoke their block synchronously: a level-1
  forward requires the enclosing block's own capture set to be non-empty
  (the propagation just put the index there), so that outer call site had
  to pass the identical allowlist gate -- synchronous invocation at every
  level chains into "the whole frame chain is live", exactly the property
  the level-0 argument already relied on. A level the enclosing frame
  cannot supply stays a real gate, not an assertion, so any shape the
  propagation does not cover degrades to today's honest `#error` rather
  than a dangling C++ name. Instrumenting every `GETUPVAR`/`SETUPVAR`
  lookup across the whole program confirmed this empirically: zero misses
  against a live capture set (every miss is a context where
  `@block_fallback_upvars` is unset, where the pre-change code errored
  identically). Named inliners (`.times`/`.each`/...) still claim their own
  call sites BEFORE this pass sees them, so no inlined site's codegen is
  affected.

  Verified against the real whole-program diagnostic: compiled entry
  points 2258 -> 2286, method-level coverage 97.4% -> 98.6%, methods left
  on the interpreter 60 -> 32, `#error unhandled opcode BLOCK` 35 -> 5,
  `SENDB` 35 -> 5, total `#error` markers 112 -> 50, `BLOCK_FALLBACK`
  sites 330 -> 394. The `SEND/SSEND ... splat and/or keyword` count also
  drops 22 -> 20, a real second-order win rather than a silent change:
  `RPG2k::Scene::Map#open_message` is one of the newly-compiled methods,
  so its two keyword call sites in `#drive_parallel_wait` now MONO-
  devirtualize to direct C++ calls instead of `#error`ing.
  `scripts/rpg2k_logic_check.rb` (1201 checks),
  `scripts/rpg2k_scene_check.rb` (1062 checks), and
  `scripts/lcf_testbed_check.rb` all still pass unchanged. Directly
  inspected real generated output for `quads_from_quarters`: the method
  captures `&r1`/`&r3`, the `|j|` body forwards both pointers unchanged
  into the `|i|` body's env alongside `&r1` for its own `j`, and that body
  reads `*bc2cpp_upvar_u1_1` / `*bc2cpp_upvar_1` / `*bc2cpp_upvar_u1_3` --
  matching the disassembly operand for operand. A real `g++ -std=c++17
  -fsyntax-only` compile of the actual `SKIP_UNSUPPORTED=1` generated
  output confirms the exact same 17 pre-existing, already-documented,
  unrelated errors as immediately before this change and zero new ones.

  The 8 `BLOCK`/`SENDB` markers that remain are four separate methods,
  none of them an upvar problem: three are a `yield` inside the block body
  (`#error unhandled opcode BLKPUSH` -- `LCF::Array2D#each`,
  `RPG2k::Scene::MapViewer#each_event_position`,
  `Game::Battle#auto_battle_best_target`; forwarding the enclosing
  method's own block into a standalone cfunc is a materially separate
  feature), and one is a splat/keyword call inside the block body
  (`Game::State.restore_pictures`' own `show_picture` at `n=1|nk=13`,
  which belongs to the splat/keyword bucket). `flat_map` was investigated
  as an allowlist addition and VERIFIED sound -- `Enumerable#flat_map`
  (mruby-enum-ext) calls the block synchronously inside `each` and never
  stores it, `Enumerator::Lazy#flat_map` (which DOES store it in a closure)
  is unreachable because `mruby-enum-lazy` is absent from this project's
  explicit `build_config.rb` gem list and no override exists anywhere in
  the closed world -- but it is deliberately NOT added yet: admitting it
  compiles `RPG2k::Scene::Map#global_animation_targets`, whose inner block
  then reaches a PRE-EXISTING, unrelated `KEYWORD_CALLSITE_SUPPORT` MONO
  bug (the devirtualized direct call emits an extra literal `1` presence
  flag per keyword that the callee's real signature does not declare,
  already failing at 12 other call sites today), taking the documented
  syntax-only error count from 17 to 18. It waits on that arity bug; the
  safety argument is recorded in full next to the allowlist so the entry
  is a one-word change afterwards.
