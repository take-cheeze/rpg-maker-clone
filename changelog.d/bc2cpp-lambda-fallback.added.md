- `tools/bc2cpp/bc2cpp.rb` now compiles a `LAMBDA` instruction (`->() {
  }`/`lambda { }`, ops.h: `R[a] = lambda(Irep[b],L_LAMBDA)`) whose own
  child irep is safe to run standalone, reusing BLOCK_CFUNC_FALLBACK_
  SUPPORT's own machinery: the child irep is compiled as a genuine,
  standalone C++ function and wrapped in a real cfunc-backed `RProc`
  (`mrb_proc_new_cfunc_with_env`, self captured at construction time --
  same mechanism BLOCK_CFUNC_FALLBACK_SUPPORT's own self-capture round
  already built). Unlike a `BLOCK`/`SENDB` region, a `LAMBDA` never calls
  anything itself -- it only BUILDS a value -- so the new glue
  (`emit_lambda_fallback_glue`) just stores `mrb_obj_value(proc)` into
  the destination register, with no `mrb_funcall_with_block` at all. The
  actual "compile this child irep + wrap as a cfunc-backed RProc"
  function (`emit_block_fallback_fn`, now renamed `emit_proc_fallback_fn`
  since it is genuinely shared, not copy-pasted) needed ZERO changes to
  support this: it already only reads `region[:block_irep]`/
  `region[:block_addr]`, both of which `recognize_lambda_fallback_regions`
  populates the same way `recognize_block_fallback_regions` does. A
  second small shared helper, `emit_rproc_construction`, was pulled out
  of the RProc-building 2 lines both `emit_block_fallback_glue` and the
  new `emit_lambda_fallback_glue` need identically.

  **The return/break investigation this round was built around, and its
  real answer**: real Ruby's own well-known rule is that a lambda's own
  `return`/`break` is an ORDINARY return from the lambda itself, never
  the non-local exit a plain block's `return`/`break` needs --
  `block_fallback_safe?` rejects `RETURN_BLK`/`BREAK` outright for
  exactly that reason (no way to build a genuine non-local exit once a
  block body is a standalone top-level C++ function, possibly several C
  call frames deep). Investigated for real, not assumed either way:

  - `3rd/mruby/include/mruby/opcode.h`: `#define OP_L_LAMBDA
    (OP_L_STRICT|OP_L_CAPTURE)` -- a LAMBDA-constructed proc is
    unconditionally `MRB_PROC_STRICT`, unlike `OP_L_BLOCK`
    (`OP_L_CAPTURE` alone).
  - `3rd/mruby/src/vm.c`: `CASE(OP_RETURN_BLK)` and `CASE(OP_BREAK)`
    BOTH start with `if (MRB_PROC_STRICT_P(ci->proc)) goto
    NORMAL_RETURN;` -- an ordinary, same-frame return, exactly
    `OP_RETURN`'s own semantics, whenever the executing proc is strict.
  - `3rd/mruby/mrbgems/mruby-compiler/core/codegen.c`: `codegen_lambda`
    (real `->() { }`) calls `lambda_body(s, ..., blk=1)` -- the SAME
    `blk=1` a plain block's own `NODE_BLOCK` codegen passes (pushing the
    identical `LOOP_BLOCK` scope). `codegen_return`'s own RETURN_BLK-vs-
    RETURN choice (`if (s->loop) ... OP_RETURN_BLK ... else ...
    OP_RETURN`) depends only on lexical loop nesting, NOT on lambda-vs-
    block -- so a lambda's own `return`/`break` compiles to the exact
    SAME `RETURN_BLK`/`BREAK` opcodes an identically-shaped block would
    use. Confirmed against real `mrbc -v` disassembly (not just source
    reading): `->(x) { return x * 2 }.call(5)` disassembles its own
    child irep to `RETURN_BLK R3`, and a bare `break 42` (no enclosing
    `while` at all) inside a `lambda do |x| ... end` body disassembles to
    a plain `BREAK R3` -- both real, hit-in-practice shapes, not
    hypothetical.

  So the opcode itself never distinguishes a lambda's `return`/`break`
  from a block's -- but the STRICT flag on the enclosing proc does, and
  `recognize_lambda_fallback_regions` already knows it is compiling a
  LAMBDA (never BLOCK/SENDB/SSENDB) by construction. This IS a real,
  confirmed asymmetry, not just a scoped-down copy of BLOCK support: a
  new `lambda_fallback_safe?`/`LAMBDA_FALLBACK_UNSAFE_OPS` (mirroring
  `block_fallback_safe?`'s own structure) lets `RETURN_BLK`/`BREAK`
  through where `block_fallback_safe?` still rejects them, and
  `compile_insn` gained a matching `RETURN_BLK` comment update plus a new
  `BREAK` case (previously `BREAK` had no case in `compile_insn` at all --
  it was reachable only via the unrelated `compile_block_body_insn`'s own
  jump-based EACH_BLOCK_SUPPORT inlining, which intercepts it before ever
  delegating to `compile_insn`), both translating identically to a plain
  `return r<n>;` -- correct because nothing here ever re-enters the real
  VM's own `OP_RETURN_BLK`/`OP_BREAK` dispatch for this body at runtime;
  the static translation below IS the whole runtime behavior, so the
  synthesized cfunc-backed RProc needs no matching real `MRB_PROC_STRICT`
  flag either. `GETUPVAR`/`SETUPVAR` (no captured-`REnv` support),
  nested `LAMBDA`/`BLOCK`/`SENDB`/`SSENDB` (no recursive fallback support
  this round), and `RESCUE`/`RAISEIF`/`EXCEPT` (no rescue-region support)
  are still rejected, identically to `block_fallback_safe?`'s own
  reasoning for each.

  Verified via a real whole-program regen (fresh, correctly-patched host
  `mrbc`): whole-program `unhandled opcode LAMBDA` 3 -> 1 (the new
  `lambda bodies compiled via cfunc/RProc fallback (LAMBDA_FALLBACK)`
  section this round also added to `scripts/bc2cpp_coverage_report.rb`
  reads 2, matching exactly). `compiled clean` 2006 -> 2007, whole-program
  `#error` total 681 -> 679 (every OTHER `#error` reason unchanged from
  baseline). Both fixed real call sites belong to `RPG2k::Scene::Map`
  (`mruby-rpg2k/mrblib/scene/map.rb`): `#open_message`'s own `names =
  ->(id) { actor_name(id) }` -- an implicit-self call inside the lambda
  body, devirtualized MONO straight to `RPG2k__Scene__Map_actor_name_impl`
  using the correctly self-captured receiver, confirmed by tracing the
  real generated code -- and `#append_choice_lines`' own analogous
  lambda. The third, previously-undifferentiated real site,
  `RPG2k::Scene::Menu#draw_status_row`'s own `line = ->(n) { y + n *
  LINE_H }`, stays honestly `#error`'d: real `mrbc -v` disassembly of the
  exact same shape (`->(n) { y + n * K }` capturing an enclosing local)
  confirms its child irep opens with `GETUPVAR R3 1 0` -- a real outer-
  local capture, still out of scope this round, exactly like
  `block_fallback_safe?`'s own stance -- `tools/bc2cpp/compiled_gems.rb`'s
  own now-stale comment (previously describing ALL LAMBDA sites as a
  "permanently out-of-scope closure-creation gap") was corrected to say
  so precisely, not deleted.

  `bash scripts/bc2cpp_coverage_check.bash`: fresh. `scripts/
  rpg2k_logic_check.rb` (1201 checks), `scripts/rpg2k_scene_check.rb`
  (1062 checks), `scripts/lcf_testbed_check.rb` all still pass. A full
  whole-program `g++ -fsyntax-only` compile wasn't reachable in this
  session's own sandbox (no SDL2 devshell, and the `3rd/mruby` submodule
  itself isn't checked out in this worktree -- read from the main
  checkout's own copy instead, never staged/modified); instead, directly
  compiled a minimal `g++ -std=c++17 -fsyntax-only` smoke test
  reproducing the exact new `mrb_proc_new_cfunc_with_env`-into-a-register
  shape (no dispatch) plus the RETURN_BLK/BREAK-as-plain-return shape,
  against real mruby headers (`/tmp/freshbuild/mruby/host/include`) --
  clean.
