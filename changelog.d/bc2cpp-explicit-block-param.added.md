- `tools/bc2cpp/bc2cpp.rb` can now compile a method declaring a real named
  block parameter -- `def each(&blk); all.each(&blk); end` (`Game::Actors`,
  `Game::Party`) and mruby core's own `Array#sort`/`Array#sort!`
  (`def sort(&block)`) -- previously an honest `#error ... has
  non-mandatory arguments (optional/rest/keyword/block)` regardless of how
  simple the rest of the method was, the same bucket BLKPUSH_YIELD_SUPPORT
  (bare `yield`) already carved a hole in for a *different* shape.

  Confirmed via a fresh `mrbc -v` disassembly of
  `def each(&blk); [1,2,3].each(&blk); end` that this is structurally
  distinct from a bare `yield`: no `BLKPUSH`/`BLKCALL` anywhere. ENTER's own
  block-arity flag (`fields[6]`, the same field `rest_only_arity?`/
  `optional_arg_table`/`keyword_arg_table` already parse out and name
  `block`) is set (`ENTER 0:0:0:0:0:0:1:0`), and the real block value simply
  arrives via the *ordinary* entry-argument calling convention, landing in
  register `mand+1` (here R1) exactly like an `(mand+1)`-th positional
  argument would, then gets copied by a plain `MOVE` into whichever
  register mrbc's own codegen chose for the named local (`blk`) -- no new
  `compile_insn` opcode case needed at all, only the entry wrapper needs to
  populate that register correctly.

  New `block_param_arity?(irep)` predicate (mirrors `rest_only_arity?`
  exactly) gates a new `has_blk` arity shape, mutually exclusive with every
  other non-mandatory shape by construction (each of those guards already
  requires this same ENTER field to be zero). Reuses the *exact* same extra
  `mrb_value bc2cpp_blk` `_impl` parameter and `mrb_get_args`'s own `&`
  format specifier BLKPUSH_YIELD_SUPPORT already established for "the real
  block value this call was given" -- the two mechanisms differ only in
  what happens to it afterward: BLKPUSH_YIELD_SUPPORT leaves it as a bare
  parameter, read wherever `BLKPUSH` needs it; this one writes it into
  register `mand+1` once, at the very top of the impl body, before the
  ordinary instruction loop runs, since that register is a real named local
  every subsequent `MOVE`/`SEND`/`GETUPVAR` already expects to find it in.

  Composes for free with the pre-existing EXPLICIT_BLOCK_ARG mechanism
  (`&expr` forwarded to another call): `Game::Actors#each`/
  `Game::Party#each` both immediately forward their own `&blk` straight
  into `all.each(&blk)`/`@actors.each(&blk)`, and the generated code shows
  exactly that -- `r1 = bc2cpp_blk;` followed by the existing
  `mrb_funcall_with_block(..., r4)` glue, unmodified.

  Verified against the real whole-program diagnostic: compiled entry
  points 2241 -> 2245, method-level coverage 96.6% -> 96.8%, "has
  non-mandatory arguments" bucket 8 -> 4 (`Array#sort`, `Array#sort!`,
  `Game::Actors#each`, `Game::Party#each` all now compile clean; the
  remaining 4 -- `Game::Battle#deal_attack`, `Game::Battle#initialize`,
  `RGSS::ErrorReport::Tee#method_missing`, `RPG2k::Scene::Map#build_animation`
  -- are a different, not-yet-investigated shape), total `#error` markers
  132 -> 128. `scripts/rpg2k_logic_check.rb` (1201 checks),
  `scripts/rpg2k_scene_check.rb` (1062 checks), and
  `scripts/lcf_testbed_check.rb` all still pass unchanged. Directly
  inspected real generated output for both `Game::Actors#each` and
  `Game::Party#each`. A real `g++ -std=c++17 -fsyntax-only` compile of the
  actual `SKIP_UNSUPPORTED=1` generated output confirms the exact same 17
  pre-existing, already-documented, unrelated errors as immediately before
  this change and zero new ones.
