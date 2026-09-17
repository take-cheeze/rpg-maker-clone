- `tools/bc2cpp/bc2cpp.rb`'s `BLOCK_FALLBACK` mechanism now compiles a
  block-carrying call site that ALSO passes its own explicit positional
  argument(s) alongside the block -- `ary.reduce(0) { |acc, x| ... }`,
  `ary.each_with_object(h) { |x, memo| ... }`, `ary.each_slice(2) { ... }`,
  and the like. Previously `recognize_block_fallback_regions` hard-required
  `n=0` at the `SENDB`/`SSENDB` call site (`BLOCK`/`SENDB`'s own register
  layout matched only "receiver, then the block, nothing else"), rejecting
  every real fixed-count-args-plus-block call outright.

  Generalized to any fixed `n` (still never a real splat, `n=*` --
  SPLAT_CALL_ARGS keeps its own honest `#error`, no static register layout
  to build `argv` from -- and never a keyword call, `n=k|nk=j`: confirmed
  against `recognize_block_fallback_regions`'s own new comment,
  `mrb_funcall_with_block` can never carry keywords at all, `ci->nk = 0` in
  mruby's own `funcall_args_capture`, so there is no sound dynamic-dispatch
  translation for that shape regardless of block support). Register layout
  (`block_reg == dest_reg + n + 1`, args at `dest_reg + 1 .. dest_reg + n`)
  confirmed against the identical shape `recognize_accum_regions`'s own
  `reduce(init)` case (`n=1`) already established and verified against real
  `mrbc -v` disassembly. `emit_block_fallback_glue` already built its own
  `argv` from `region[:n]` generically (added ahead of time when `n` was
  still always `0`) -- this change only had to widen the recognizer's own
  gate and register-offset check; no other emitter needed to change.

  Verified against the real whole-program diagnostic: compiled entry
  points 2141 -> 2151, method-level coverage 92.5% -> 92.8%, `#error
  unhandled opcode BLOCK` 150 -> 127, `SENDB` 137 -> 114, total `#error`
  markers 390 -> 344, `BLOCK_FALLBACK` sites 192 -> 215.
  `scripts/rpg2k_logic_check.rb` (1201 checks), `scripts/rpg2k_scene_check.rb`
  (1062 checks), and `scripts/lcf_testbed_check.rb` all still pass
  unchanged. Directly inspected real generated output: `Game::State#to_h`'s
  own `each_with_object(h) { ... }` (`mrb_value bc2cpp_blk_argv_182[] = {
  r52 };` alongside the RProc, `mrb_funcall_with_block(M, r51, ...,
  1, bc2cpp_blk_argv_182, ...)`) and several real `reduce(init)` sites that
  fall through to this mechanism (non-Array receiver or block arity the
  dedicated `recognize_accum_regions` inline emitter doesn't cover) --
  both wired correctly. A real `g++ -std=c++17 -fsyntax-only` compile of
  the actual `SKIP_UNSUPPORTED=1` generated output, diffed line-for-line
  against the same compile from before this change, confirms the exact
  same 17 pre-existing, already-documented, unrelated errors (only their
  line numbers shifted) and zero new ones.
