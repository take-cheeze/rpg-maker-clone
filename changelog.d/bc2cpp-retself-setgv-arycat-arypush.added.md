- `tools/bc2cpp/bc2cpp.rb`'s `compile_insn` gains real translations for four
  opcodes that previously fell straight to the generic `#error unhandled
  opcode` fallback, leaving their whole enclosing method on the slow
  bytecode-interpreted path: `RETSELF`, `SETGV`, `ARYPUSH`, `ARYCAT`.

  - **`RETSELF`** (Z, no operand) -- ops.h's own comment (`/* return self
    */`) undersells it slightly: real `OP_RETSELF` (`src/vm.c`) is `a = 0;
    goto NORMAL_RETURN;`, the identical bare-value path `OP_RETURN` itself
    takes, with the register hardwired to 0 (`self`, real mruby calling
    convention). Confirmed against `mrbgems/mruby-compiler/core/codegen.c`'s
    own `gen_return`: mrbc only ever emits this opcode as a peephole fusion
    of `LOADSELF` immediately followed by a `RETURN` reading that same
    register, i.e. a plain `self`/implicit-self return. Translates straight
    to `return self;` (this generated function's own real parameter) --
    exactly as trivial as the file's existing `RETURN`/`RETNIL`/`RETFALSE`/
    `RETTRUE` handling.
  - **`SETGV`** (BB) -- the write-direction symmetric opcode to the
    already-handled `GETGV`, `$foo = value` -> `mrb_gv_set(mrb, irep->syms[b],
    regs[a])` (`mruby/variable.h`, already `#include`d). One real gotcha
    caught by reading `src/codedump.c` directly rather than assuming
    symmetry with GETGV's own disassembly shape: `SETGV` prints its two
    operands in **reversed** order (`"SETGV\t\t%s\tR%d"`, symbol first) vs.
    `GETGV`'s `"GETGV\t\tR%d\t%s"` -- so unlike GETGV's own `^R`-anchored
    register capture, SETGV's extraction has to search unanchored instead.
  - **`ARYPUSH`** (BB) -- push `b` consecutive registers onto the array
    already held in `R[a]`, real `OP_ARYPUSH` (`src/vm.c`):
    `mrb_ensure_array_type(mrb, regs[a]); for (i=0;i<b;i++)
    mrb_ary_push(mrb, regs[a], regs[a+i+1]);`, a pure in-place mutation
    (`mruby/array.h`'s public `mrb_ary_push`, same call pattern this file's
    `emit_sort_inline`/collect-block-inlining code already uses elsewhere).
  - **`ARYCAT`** (B) -- concatenate `R[a+1]` onto `R[a]`. The terse ops.h
    comment (`/* ary_cat(R[a],R[a+1]) */`) undersells real `OP_ARYCAT`
    too: it's `mrb_value splat = mrb_ary_splat(mrb, regs[a+1]); if
    (mrb_nil_p(regs[a])) regs[a] = splat; else { mrb_ensure_array_type(mrb,
    regs[a]); mrb_ary_concat(mrb, regs[a], splat); }` -- `R[a+1]` is
    splatted first (`mrb_ary_splat`, `src/array.c`: an Array is duplicated
    as-is, anything else is converted via a real `#to_a` call if it
    responds to one, else wrapped as a one-element array), and `R[a]` has a
    nil-becomes-the-splat special case ahead of the real concat.

  Both `ARYPUSH` and `ARYCAT` needed a real invariant, not a guess, before
  translating `R[a]` unconditionally: `mrbgems/mruby-compiler/core/
  codegen.c` emits both opcodes from exactly two functions each --
  `gen_values` (`foo(*a, b)`-shaped call-argument splats) and
  `codegen_array` (`[*a, b]`-shaped array-literal splats) -- and every one
  of the real call sites (7 for `ARYPUSH`, 2 for `ARYCAT`) is gated behind
  a `first`/`!first`-style flag that only ever clears once a `genop_2(s,
  OP_ARRAY, ...)` has already written that identical register (directly,
  or -- `codegen_call_assign`'s own >13-argument overflow packing, the one
  indirect `ARYPUSH` case -- via its own forced `OP_ARRAY` first). So
  `R[a]` is provably always a real, already-built Array at every real
  occurrence, never nil, and the real VM's own `mrb_ensure_array_type`
  guard is unconditionally a no-op here -- confirmed by grepping every
  `OP_ARYCAT`/`OP_ARYPUSH` emission site in the whole vendored mruby tree
  (only those two functions, no other gem generates raw bytecode), not
  assumed. `R[a+1]`/the pushed source registers get no such guarantee, so
  `ARYCAT` still calls the real `mrb_ary_splat` rather than assuming its
  argument is already an Array.

  Verified via a real whole-program regen
  (`MRBC=.../mrbc ruby scripts/bc2cpp_coverage_report.rb`): the whole-
  program `#error` table drops all four opcodes to zero (`RETSELF` 3 -> 0,
  `SETGV` 2 -> 0, `ARYPUSH` 2 -> 0, `ARYCAT` 8 -> 0; total `#error` count
  816 -> 801, method-level coverage 85.9% -> 86.0%, 1969 -> 1972 methods
  compiled clean). `scripts/rpg2k_logic_check.rb` (1201 checks),
  `scripts/rpg2k_scene_check.rb` (1062 checks), and
  `scripts/lcf_testbed_check.rb` all still pass unchanged. Independently
  smoke-tested the real generated C++ shape for all four opcodes (a
  minimal class exercising `self`-only return, `$global = ...`, `[*a,
  *b]`, and `[*a, 1, 2]` -- the last one specifically to force `ARYPUSH`
  after an `ARYCAT`, confirmed against real `mrbc -v` disassembly first):
  `g++ -std=c++17 -fsyntax-only` against the actual generated output,
  clean.
