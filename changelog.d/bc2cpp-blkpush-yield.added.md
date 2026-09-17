- `tools/bc2cpp/bc2cpp.rb` can now compile a bare `yield(...)` -- mrbc's own
  `BLKPUSH`+`BLKCALL` fast path (codegen.c's `codegen_yield`) for a plain
  block call with no keywords/splat/>=15 args. `BLKCALL` itself already had
  a full, correct translation (`mrb_yield_argv`), but `BLKPUSH` -- which
  fetches the CURRENT call's own received block into a register before
  `BLKCALL` can invoke it -- had no `compile_insn` case at all, so every
  real occurrence hit the generic `#error unhandled opcode BLKPUSH` first
  regardless of how simple the rest of the method was.

  Scoped to the real shape every occurrence in this whole program actually
  has (confirmed via the real whole-program registry): `BLKPUSH`'s own
  `lv` (level) operand is `0` -- "this call frame's own block," never an
  outer scope's (`lv > 0` walks mruby's own `uvenv` chain instead, a
  different value this compiler has no register/pointer for, same
  "genuinely not modeled" territory as a depth>0 `GETUPVAR`/`SETUPVAR`) --
  inside an otherwise plain mandatory-arity method (`compile_method`'s own
  new `needs_blk_param` prescan gates this to `mandatory_ok` methods only,
  never interacting with the optional/keyword/rest entry-wrapper branches).

  The entry wrapper extracts the real block value via `mrb_get_args`' own
  `&` format specifier (mruby's public API for "the block passed to this
  call," the same value `BLKPUSH`'s own raw `regs[1+offset]` stack read
  would find) appended to the same call that already unpacks this method's
  positional arguments, forwards it as one new `_impl` parameter
  (`bc2cpp_blk`), and `compile_insn`'s new `BLKPUSH` case reads it straight
  back -- reproducing real `vm.c`'s own `LocalJumpError` ("unexpected
  yield") when no block was actually given, since `mrb_get_args`' own `&`
  (unlike `BLKPUSH`'s own raw stack read) returns nil rather than raising
  by itself.

  Verified against the real whole-program diagnostic: compiled entry
  points 2151 -> 2154, method-level coverage 92.8% -> 92.9%, `#error
  unhandled opcode BLKPUSH` 3 -> 0 (every real occurrence in this program).
  `scripts/rpg2k_logic_check.rb` (1201 checks), `scripts/rpg2k_scene_check.rb`
  (1062 checks), and `scripts/lcf_testbed_check.rb` all still pass
  unchanged. Directly inspected real generated output for both real sites
  (`RPG2k::Scene::Battle#cached_bitmap`/`RPG2k::Scene::Map#cached_bitmap`'s
  own `cache[key] = yield`): the entry wrapper's own
  `mrb_get_args(M, "oo&", &cache, &key, &bc2cpp_blk);` and the body's own
  `if (mrb_nil_p(bc2cpp_blk)) { ...LocalJumpError...} r7 = bc2cpp_blk;`
  feeding straight into the existing `BLKCALL` case's own `mrb_yield_argv`
  call -- wired correctly. A real `g++ -std=c++17 -fsyntax-only` compile of
  the actual `SKIP_UNSUPPORTED=1` generated output confirms the exact same
  17 pre-existing, already-documented, unrelated errors as immediately
  before this change (only their line numbers shifted) and zero new ones.
