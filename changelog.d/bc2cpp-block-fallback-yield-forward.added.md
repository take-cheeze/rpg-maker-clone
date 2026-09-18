- `tools/bc2cpp/bc2cpp.rb`'s `BLOCK_FALLBACK` mechanism can now compile a
  block body that itself contains a `yield` -- `def each; @data.size.times
  { |i| v = self[i]; yield i, v unless v.nil? }; end`, this program's own
  `LCF::Array2D#each`. The standalone cfunc a block body compiles into has
  no block of its own to yield to, so such a `yield` has to reach the
  ENCLOSING METHOD's own received block; that was the single cause behind
  the entire remaining `BLOCK`/`SENDB` bucket except one splat/keyword site,
  and the `#error unhandled opcode BLKPUSH` the deep-upvar round diagnosed
  and deferred.

  Real `mrbc -v` disassembly is what settles the shape, and it is NOT the
  level-less reference it could plausibly have been -- `BLKPUSH` carries a
  real level operand, the trailing parenthesised field:

        irep (method each)   nregs=4 nlocals=2      -- R1 is the block slot
          GETIV R2 @data / SEND0 R2 :size
          BLOCK R3 I[0]  / SENDB R2 :times n=0
        irep (block |i|)     nregs=8 nlocals=4  R1:i  R3:v
          BLKPUSH  R4  0:0:0:0 (1)      ; lv == 1
          BLKCALL  R4  2

  versus the same `yield` written directly in a method body, which is the
  shape `BLKPUSH_YIELD_SUPPORT` already handled:

        irep (method plain)
          BLKPUSH  R2  0:0:0:0 (0)      ; lv == 0
          BLKCALL  R2  2

  `3rd/mruby/src/vm.c`'s own `CASE(OP_BLKPUSH, BS)` decodes the 16-bit
  operand as `m1=(b>>11)&0x3f, r=(b>>10)&0x1, m2=(b>>5)&0x1f, kd=(b>>4)&0x1,
  lv=(b>>0)&0xf`, then `if (lv == 0) stack = regs + 1; else { struct REnv *e
  = uvenv(mrb, lv-1); ...; stack = e->stack + 1; }` and reads
  `stack[m1+r+m2+kd]` -- so `lv` names a frame exactly the way GETUPVAR's
  own level operand does, and `m1:r:m2:kd` is the ENCLOSING method's own
  ENTER argument spec, giving the register offset of that method's block
  slot. Checked operand for operand against the disassembly above:
  `each`'s `ENTER 0:0:0:0` and `nlocals=2` put its block in R1, which is
  `regs[1 + 0]`; `def best(targets)`'s `ENTER 1:0:0:0` and `nlocals=5` put
  its block in R2, which is `regs[1 + 1]`, and its block body's own
  `BLKPUSH R4 1:0:0:0 (1)` carries exactly that `m1=1`.

  Unlike an upvar there is only ever ONE possible answer and no index to
  disambiguate, which is what makes a by-value capture correct. mrbc's own
  `codegen_yield` (`3rd/mruby/mrbgems/mruby-compiler/core/codegen.c`)
  computes the level as `int lv = 0; s2 = s; while (!s2->mscope) { lv++; s2
  = s2->prev; if (!s2) break; }` and then takes `s2->ainfo` -- it walks
  strictly outward and STOPS at the first METHOD scope. A block scope is
  never `mscope`, so `lv` inside a block body is always >= 1 and always
  lands on the enclosing method, never on an intervening block (a block has
  no block of its own) and never on a method further out. `yield` outside
  any method scope is a compile-time `"invalid yield (SyntaxError)"`, so
  there is no unanswerable case either.

  `block_blk_needs` is the BLKPUSH analogue of `block_upvar_needs`, with the
  identical child-propagation rule (a child's `l` becomes `l - 1`, for
  `l >= 1`); a child's `l == 0` deliberately contributes nothing, since that
  is a nested `def`'s own irep asking for its OWN block. The enclosing
  method's block value is then captured into the RProc's env at
  `mrb_proc_new_cfunc_with_env` construction time, exactly where `self` and
  the upvar pointers already are -- BY VALUE, not by address, because the
  block slot is only ever READ (`regs[a] = stack[offset]`; no opcode writes
  back through it) and because a value in the env array is GC-rooted by the
  RProc itself rather than borrowed from a frame. It lands in the last env
  slot, after `self` and after every upvar pointer, so all 396 already-
  shipping `BLOCK_FALLBACK` bodies generate byte-for-byte identical C++.
  `compile_insn`'s own `BLKPUSH` case matches on the exact level rather than
  on `lv > 0` generally, since vm.c walks `uvenv(mrb, lv-1)` -- a different
  frame for every distinct `lv`, and this compiler holds exactly one of
  them.

  Deliberately a bounded slice: only `blk_needs == [1]` is modelled, i.e.
  every BLKPUSH in the subtree resolves to the frame the call site itself
  sits in. A `yield` nested TWO block frames deep (`lv == 2`) is modelable
  in principle by forwarding the captured value one level further, exactly
  the way `DEEP_UPVAR_CAPTURE_SUPPORT` forwards an upvar pointer, but a real
  whole-program sweep found no such site anywhere in this closed world --
  every BLKPUSH inside a block body is `lv == 1` -- so it stays at the
  honest `#error` rather than shipping untested. `needs_blk` never gates
  region ADMISSION either: a body whose BLKPUSH this cannot answer still
  produces its region and still fails on its own unhandled-opcode `#error`,
  exactly as before, so every shape not newly supported is unchanged.

  Soundness reuses the existing `BLOCK_FALLBACK_UPVAR_SAFE_METHODS`
  allowlist, and needs it for a subtly different reason than upvar capture
  does. The captured block cannot dangle -- it is an `mrb_value` copy, GC-
  rooted by the env -- but the block it names is an ordinary irep-backed
  RProc whose OWN env is on the caller's stack, so invoking it after the
  enclosing method's caller returned would be the escaped-block hazard. Real
  vm.c refuses exactly that itself (`if (!e || (!MRB_ENV_ONSTACK_P(e) &&
  e->mid == 0) || MRB_ENV_LEN(e) <= offset+1) RAISE_LIT(mrb,
  E_LOCALJUMP_ERROR, "unexpected yield")`); the allowlist is what keeps this
  compiler from having to, since every receiver on it has already been hand-
  vetted to invoke its block synchronously and never store it. vm.c's own
  nil check (`if (mrb_nil_p(stack[offset])) RAISE_LIT(... "unexpected
  yield")`) is reproduced directly, as it already was for `lv == 0`.
  `LAMBDA_FALLBACK` deliberately gets none of this: a lambda-constructed
  proc can genuinely escape and outlive the frame whose block it would be
  capturing, which is precisely what the allowlist rules out for a
  `BLOCK_FALLBACK` site and nothing rules out for a lambda.

  Verified against the real whole-program diagnostic: compiled entry points
  2287 -> 2290, method-level coverage 98.6% -> 98.8%, methods left on the
  interpreter 31 -> 28, `#error unhandled opcode BLOCK` 4 -> 1, `SENDB`
  4 -> 1, total `#error` markers 48 -> 42, `BLOCK_FALLBACK` sites 396 ->
  399. The three newly-compiled methods are `LCF::Array2D#each`,
  `RPG2k::Scene::MapViewer#each_event_position` and
  `Game::Battle#auto_battle_best_target`. A full diff of the actual
  generated C++ before and after touches ONLY those three methods and their
  three forward declarations -- every other byte of the 14MB whole-program
  output is identical. The dynamic-dispatch total moves 14904 -> 14919, and
  that +15 is exactly the funcall count of the three newly-SHIPPED bodies
  (3 + 10 + 2, counted directly in the `SKIP_UNSUPPORTED=1` output), not a
  regression elsewhere. Directly inspected the real generated output:
  `Array2D#each` captures `{ self, bc2cpp_blk }` and its body reads
  `bc2cpp_blk` at env slot 1; `auto_battle_best_target` composes with deep
  upvars and captures `{ self, &r3, &r4, bc2cpp_blk }`, reading the block at
  slot 3 with the `_impl` parameter order `self, upvars, blk, args` matching
  operand for operand. `scripts/rpg2k_logic_check.rb` (1201 checks),
  `scripts/rpg2k_scene_check.rb` (1062 checks) and
  `scripts/lcf_testbed_check.rb` all still pass unchanged. A real `g++
  -std=c++17 -fsyntax-only` compile of the actual `SKIP_UNSUPPORTED=1`
  generated output reports ZERO errors, the same as immediately before this
  change.

  One real, previously-unrecorded property of the `BLOCK_FALLBACK`
  mechanism was measured while verifying this and is worth writing down: a
  cfunc-backed proc does NOT get Ruby's Proc auto-splat. Confirmed by
  building a stock mruby and running the real VM, not by reading source --
  a `mrb_proc_new_cfunc_with_env` proc whose body calls `mrb_get_args(mrb,
  "oo", ...)`, passed as the block to `Hash#each`, raises `ArgumentError:
  wrong number of arguments (given 1, expected 2)`, because
  `Hash#each` (`3rd/mruby/mrblib/hash.rb`) calls `block.call([keys[i],
  vals[i]])` -- ONE Array argument, which only an irep-backed block's own
  `OP_ENTER` would destructure. This is pre-existing and systemic rather
  than anything this change introduces: the baseline output already has 110
  block-fallback cfuncs with 2+ mandatory block params. It is also narrow --
  `Hash#each` is the only common enumerable that packs its yield into one
  Array (`Array#each` yields 1 value, `each_with_index` yields 2 separately,
  both verified on the same real VM), and `HASH_EACH_SUPPORT` already claims
  every site whose receiver is PROVABLY a Hash before the fallback pass sees
  it. The one new 2-param body added here,
  `RPG2k::Scene::MapViewer#each_event_position`'s `events.each do |id, ev|`,
  is safe for a concrete reason: `events` is schema-typed `:Array2D`
  (`mruby-lcf/mrblib/schema.rb`, `81 => { name: :events, type: :Array2D }`),
  so it dispatches to `LCF::Array2D#each`, which yields `i, v` as two
  separate values -- and whose own newly-compiled body emits
  `mrb_yield_argv(M, blk, 2, ...)`, matching the `"oo"` extraction exactly.
  (`scripts/rpg2k_scene_check.rb`'s `fake_map` passes a plain Hash there,
  but that is `OpenStruct` test scaffolding running on the interpreter; the
  compiled gem only ever sees the real LCF record.) Proving a receiver class
  for the remaining unproven 2-param sites is a separate, mechanism-wide
  piece of work, not this round's.
