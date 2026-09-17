- `tools/bc2cpp/bc2cpp.rb`'s `BLOCK_FALLBACK` mechanism (a block-carrying
  call site compiled by wrapping its body as a standalone cfunc-backed
  `RProc`, dispatched via `mrb_funcall_with_block`) can now compile a
  block that closes over a variable from its enclosing method --
  `GETUPVAR`/`SETUPVAR` -- previously the single largest cause of a real
  `#error unhandled opcode BLOCK`/`SENDB`/`SSENDB` by a wide margin (a
  real whole-program sweep found roughly 390 of the ~419 opcode-blocked
  sites involved a closure over an outer local, out of 567 total
  remaining `#error` sites).

  The mechanism generalizes the SELF_CAPTURE_SUPPORT technique this file
  already established for `self` (boxed into `mrb_proc_new_cfunc_with_env`'s
  own env array, read back via `mrb_proc_cfunc_env_get`): since every VM
  register in a compiled method's own body is already a plain `mrb_value`
  C++ local, "capture an outer local" reduces to "read/write a specific
  `mrb_value` variable in the ENCLOSING C++ function's own stack frame" --
  a pointer to it (`mrb_cptr_value(M, &rN)`), not a copy, so a real
  Ruby closure's read/write-both-ways semantics carry over exactly (the
  accumulator idiom `total = 0; list.each { |x| total += x }; total`
  needs the block's own write to be visible after the loop returns, which
  a copy could never give). `collect_block_upvars`/`compile_insn`'s own
  new `GETUPVAR`/`SETUPVAR` cases confirmed the exact operand encoding
  against real `mrbc -v` disassembly and 3rd/mruby/src/vm.c's own
  `OP_GETUPVAR`/`OP_SETUPVAR` (`e->stack[b]`) before writing any codegen:
  the upvar index operand is literally the enclosing method's own
  register number, and the depth operand must be `0` (a deeper capture is
  refused outright, not merely unsupported -- structurally guaranteed by
  `BLOCK`/`SENDB`/`SSENDB` staying on `BLOCK_FALLBACK_UNSAFE_OPS`, so no
  nested block can ever produce a depth-1+ reference here).

  A real, separate safety question -- deliberately NOT decided by
  `block_fallback_safe?` itself -- is whether pointer-capture is sound at
  a given call site at all: unlike `self` (copied by value, so remains a
  valid handle even if a stored block outlives this call), a captured
  upvar is a raw pointer into this call's own stack frame, safe only if
  the receiver invokes the block strictly synchronously and never stores
  it for later/async invocation. This program does contain a real
  block-storing pattern (`LCF.lazy(&block)`, mruby-lcf/mrblib/schema.rb --
  not reachable from inside a compiled method body today, but proof the
  hazard isn't hypothetical), so rather than trust an arbitrary,
  dynamically-dispatched method name, a captured upvar only devirtualizes
  when the call site's own method name is on a small, hand-vetted
  `BLOCK_FALLBACK_UPVAR_SAFE_METHODS` allowlist -- built from this
  program's own real whole-program GETUPVAR/SETUPVAR-blocked call sites
  (`each`, `map`, `times`, `select`, `find`, `any?`, ..., every one either
  mruby's own native C-implemented Array/Enumerable method or a
  same-shaped domain method confirmed synchronous by reading its body).
  A block with no upvars at all needs no such gate, identical to this
  mechanism's pre-existing behavior. `LAMBDA_FALLBACK` (a `->(){}`/
  `lambda{}` literal, which is explicitly meant to be stored/escape)
  deliberately keeps `GETUPVAR`/`SETUPVAR` forbidden outright -- out of
  scope for this round, a real bigger undertaking (a lambda needs a
  heap-allocated, lifetime-extended capture, not a stack pointer).

  Verified against the real whole-program diagnostic: compiled entry
  points (real build output, zero `#error`) 2033 -> 2126 (+93 methods now
  fully clean), method-level coverage 87.9% -> 91.8%, `#error unhandled
  opcode BLOCK` 277 -> 165, `SENDB` 256 -> 145, `SSENDB` 34 -> 33, total
  `#error` markers 648 -> 420, `BLOCK_FALLBACK` sites 65 -> 177 (+112,
  matching the BLOCK/SENDB reduction exactly). `scripts/rpg2k_logic_check.rb`
  (1201 checks), `scripts/rpg2k_scene_check.rb` (1062 checks), and
  `scripts/lcf_testbed_check.rb` all still pass unchanged -- the real
  runtime-correctness evidence a pure compile-success count can't give
  (a wrong register captured, or read-vs-write swapped, would show up as
  a wrong game-logic answer here, not a compile error). Directly
  inspected real generated output for both directions: a read-only
  capture (`Game::Battle#target_enemy_index`'s `find { |x| x == target }`,
  `r4 = *bc2cpp_upvar_4;`) and a write-back (`*bc2cpp_upvar_6 = r4;`,
  several real accumulator sites), plus the real call-site env
  construction (`mrb_value bc2cpp_blk_env_93[] = { self,
  mrb_cptr_value(M, &r4) };`) and the trampoline's own matching
  `mrb_cptr(mrb_proc_cfunc_env_get(M, 1))` read-back -- all wired
  correctly. A real `g++ -std=c++17 -fsyntax-only` compile of the actual
  `SKIP_UNSUPPORTED=1` generated output confirms zero new errors: every
  one of the 176 errors it reports is a pre-existing, already-documented,
  unrelated gap (a missing `#include <mruby/numeric.h>` for
  `FIXABLE_FLOAT`/`mrb_integer_to_str`, and a pre-existing
  `RPG2k::Scene::Map#vehicle_blocks?` keyword-arg call-site arity
  mismatch) -- confirmed by checking every error occurring inside a real
  `_block_fallback_..._impl` function individually, not just counting.
