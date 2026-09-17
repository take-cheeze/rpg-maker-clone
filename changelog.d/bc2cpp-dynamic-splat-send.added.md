- `tools/bc2cpp/bc2cpp.rb` can now compile a plain positional-splat `SEND`/
  `SSEND` call site (`foo(*list)`) whose splatted source ISN'T a compile-
  time-fixed-size literal -- previously an honest `#error`, since
  SPLAT_UNROLL_SUPPORT's own register-list unrolling only ever works for a
  literal it can enumerate at compile time. `compile_dynamic_splat_send`
  covers the genuinely dynamic case instead: real `mrbc` codegen always
  builds the COMPLETE, real Array of positional arguments into
  `R(dest+1)` before a `SEND ... n=*` ever executes (an `ARRAY`-then-
  `ARYCAT` chain, or a `LOADNIL`-then-`ARYCAT` chain when the call's own
  first argument is itself a splat -- see below), so `mrb_funcall_argv`
  (mruby's own public "call with a real argc/argv pair" API) can dispatch
  straight off that register's own `RARRAY_LEN`/`RARRAY_PTR`, no per-
  element unrolling needed. Scoped to the plain-positional case only (no
  `|nk=` at all) -- `mrb_funcall*` can never carry keywords, so a non-
  literal double-splat still keeps the honest `#error`, same reasoning
  the literal-unroll path already documents for its own keyword case.

  Found and fixed a real, latent correctness gap in `ARYCAT`'s own
  codegen while grounding this in a fresh `mrbc -v` run rather than
  trusting the file's prior (incomplete) reading of codegen.c: that
  comment claimed `R[a]` (the register `ARYCAT` concatenates into) is
  PROVABLY never nil, based on `codegen_array`/`gen_values` always
  emitting an `OP_ARRAY` immediately before it -- true only when the
  call has a leading non-splat argument (`bar(a, *list)` really does
  compile `ARRAY R5 1` first). When the call's own FIRST argument is
  itself a splat (`bar(*list, *list2)`), there's no leading element for
  `OP_ARRAY` to build, and codegen emits `LOADNIL` instead -- real `OP_
  ARYCAT`'s own "nil becomes the splat" branch (src/vm.c) is live code
  there, not the dead case the prior comment assumed. `compile_insn`'s
  own `ARYCAT` case now reproduces both branches exactly (`mrb_nil_p`
  check, assign vs. `mrb_ary_concat`) instead of the unconditional
  concat it used to emit -- unreachable in shipped code until now (no
  real non-literal splat call site ever compiled far enough to reach it
  before this same round's own `compile_dynamic_splat_send` started
  relying on it), but load-bearing for this new feature and a real bug
  waiting to happen for anything else that might reach `ARYCAT` with a
  nil-starting register in the future.

  Verified against the real whole-program diagnostic: compiled entry
  points 2198 -> 2204, method-level coverage 94.8% -> 95.0%, `SEND/SSEND
  has a splat and/or keyword argument list` 33 -> 25, total `#error`
  markers 235 -> 227. `scripts/rpg2k_logic_check.rb` (1201 checks),
  `scripts/rpg2k_scene_check.rb` (1062 checks), and
  `scripts/lcf_testbed_check.rb` all still pass unchanged. Directly
  inspected real generated output: a real `move_to(*args)`-shaped call
  site compiles the full `LOADNIL`/`ARYCAT`-nil-branch/`mrb_funcall_argv`
  chain correctly end to end; 6 real whole-program call sites (including
  a real `__send__(*args)` meta-call) take this new path. A real
  `g++ -std=c++17 -fsyntax-only` compile of the actual `SKIP_UNSUPPORTED=1`
  generated output confirms the exact same 17 pre-existing,
  already-documented, unrelated errors as immediately before this change
  (only their line numbers shifted) and zero new ones.
