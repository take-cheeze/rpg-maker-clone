- `tools/bc2cpp/bc2cpp.rb`'s `BLOCK_FALLBACK` mechanism can now compile a
  block whose OWN body contains another block-carrying call --
  `ary.each { |x| x.things.each { |y| ... } }`,
  `allies.find { |a| a.actor && a.actor.id == member.id }`, and the like.
  Previously `BLOCK`/`SENDB`/`SSENDB` sat on `BLOCK_FALLBACK_UNSAFE_OPS`
  unconditionally -- a nested block-carrying call anywhere in a block's own
  body rejected that WHOLE call site outright, regardless of how simple
  the rest of the block was.

  `emit_proc_fallback_fn` now runs the identical recognize -> suppress ->
  glue pipeline `compile_method`'s own top-level loop already runs,
  recursively, on the block's OWN body: a nested region that resolves
  (same `block_fallback_safe?` gate applied to the nested block's own
  child irep) gets its own standalone cfunc/RProc, textually emitted
  before the enclosing level's own function references it; one that
  doesn't resolve just leaves the raw opcodes for `compile_insn`'s
  ordinary switch to hit (still no case for either), so the enclosing
  level's own body still gets the honest `#error`, exactly as any other
  unsupported opcode already would.

  `collect_block_upvars`'s existing depth-0-only rule already composed
  correctly with this with no change needed: a NESTED block's own depth-0
  upvar reference means "my immediate parent's own registers" (confirmed
  against real mruby bytecode semantics), and since the recursive pass now
  runs from INSIDE the outer block's own body-compile (not hoisted ahead
  of time the way top-level regions are batched), `emit_rproc_construction`'s
  own `&r#{b}` already takes the address of the right C++ function's own
  local automatically. `@block_fallback_upvars`/`@block_fallback_active`
  needed no real stack either: a recursive call for a level's own nested
  regions always fully runs and clears those two ivars back to nil/false
  BEFORE that level sets its own (never concurrent -- one call frame at a
  time). `needs_return_catch` (`compile_method`) now recurses into nested
  regions too (`block_fallback_region_has_return_blk?`), so a `return`
  buried two-or-more levels deep still gets caught by the same top-level
  `try`/`catch` it always did. Function-name uniqueness threads the
  parent's own already-unique name into each nested `fn_name` (a nested
  region's own `block_addr` lives in its parent's local address space and
  can otherwise numerically collide with an unrelated region using the
  same enclosing method).

  Verified against the real whole-program diagnostic: compiled entry
  points 2154 -> 2166, method-level coverage 92.9% -> 93.4%, `#error
  unhandled opcode BLOCK` 127 -> 112, `SENDB` 114 -> 99, total `#error`
  markers 341 -> 311, `BLOCK_FALLBACK` sites 215 -> 250.
  `scripts/rpg2k_logic_check.rb` (1201 checks), `scripts/rpg2k_scene_check.rb`
  (1062 checks), and `scripts/lcf_testbed_check.rb` all still pass
  unchanged. Directly inspected real generated output:
  `Game::Battle#sync_allies_from_party`'s own
  `@allies.find { |ally| ally.actor && ally.actor.id == member.id }`
  (itself inside an outer `each { |member| ... }`) -- the nested `find`'s
  own standalone function captures a pointer into the OUTER block's own
  `r1` (`mrb_cptr_value(M, &r1)` at the nested RProc's own construction
  site, `mrb_cptr(mrb_proc_cfunc_env_get(M, 1))` read back inside it),
  correctly wired end to end. A real `g++ -std=c++17 -fsyntax-only` compile
  of the actual `SKIP_UNSUPPORTED=1` generated output confirms the exact
  same 17 pre-existing, already-documented, unrelated errors as immediately
  before this change (only their line numbers shifted) and zero new ones.

  `LAMBDA_FALLBACK` (a `->(){}`/`lambda{}` literal) deliberately keeps its
  own separate `LAMBDA_FALLBACK_UNSAFE_OPS` unchanged -- still rejects a
  nested `BLOCK`/`SENDB`/`SSENDB` outright, out of scope for this round.
