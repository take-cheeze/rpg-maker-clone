- `tools/bc2cpp/bc2cpp.rb` can now compile a method containing `OP_JMPUW`,
  closing what was the single largest remaining `#error` bucket (7 sites).
  All 7 are plain `break`/`next` out of an ordinary `while`/`until` loop:
  `RPG2k#trim_ini_value`, `Game::Party#insert_item_in_bag`,
  `Game::Interpreter#update` (2 -- both `break if ...` in its own `until
  @waiting` loop), `Game::Interpreter#skip_to`,
  `Game::Interpreter#do_show_choices`, and
  `Game::Message.singleton#parse_bracket_value` (a `next` inside its own
  `while i < n` bracket scanner).

  Despite the opcode's own `unwind_and_jump_to(a)` description
  (`3rd/mruby/include/mruby/ops.h`), `JMPUW` is NOT an `ensure`-only
  opcode, and none of these 7 methods contains a `begin`/`rescue`/`ensure`
  at all. Every real `genjmp(s, OP_JMPUW, ...)` call site in
  `3rd/mruby/mrbgems/mruby-compiler/core/codegen.c` is a purely intra-irep
  jump: `loop_break` (`break` in a `LOOP_NORMAL`), `codegen_next`
  (`next`), `codegen_redo`, and `codegen_retry`. (`break`/`next` inside a
  *block* take codegen.c's own `else` arm instead and emit `OP_BREAK`/
  `OP_RETURN` via `gen_return`, which is why this file's own BLOCK
  machinery never saw a `JMPUW` for those.) The real `ensure` work stays
  exactly where it already was -- the separate `unhandled opcode EXCEPT`
  bucket, e.g. `Game::Battle#deal_attack` -- and is untouched here.

  Confirmed against real `mrbc -v` disassembly, not assumed: a bare
  `def trim_ini_value(s); e = s.size; while e > 0; ...; break unless ...;
  e -= 1; end; s[0, e]; end` -- no exception construct anywhere --
  compiles to `087 JMPUW 097` in an irep whose disassembly prints no
  "catch type:" header line at all (`clen == 0`).

  Soundness comes straight off `3rd/mruby/src/vm.c`'s own
  `CASE(OP_JMPUW, S)`, whose very first condition is `irep->clen > 0 &&
  (ch = catch_handler_find(irep, ci->pc, MRB_CATCH_FILTER_ENSURE))`. An
  irep with an empty catch handler table can therefore never take the
  `THROW_TAGGED_BREAK` path: it falls through to the bare `mrb->exc =
  NULL; ci->pc = irep->iseq + a; JUMP;` tail, byte-for-byte what
  `CASE(OP_JMP, S)` does (and the `CHECKPOINT_RESTORE` arm is unreachable,
  since only a throw this same instruction raised can re-enter it). New
  `jmpuw_is_plain_jump?` is exactly that whole-irep `clen == 0` test, so
  `JMPUW` compiles to the same bare `goto L<addr>` `JMP` already does --
  in `compile_insn` and, separately, in `compile_block_body_insn`, which
  must use its own `label_prefix` rather than the shared codegen's bare
  `L<addr>` for the same reason `JMP` there already does. `jump_targets`
  now lists `JMPUW` targets too (identical `S` operand shape) so the
  `goto` has a real label to land on.

  Deliberately the whole-irep test rather than the VM's finer per-pc
  handler-range check, because a genuinely unsound case exists and must
  keep `#error`ing: real disassembly of `while i < 10; begin; break if
  a[i] == 3; i += 1; ensure; a.tick; end; end` gives `catch type: ensure
  begin: 0019 end: 0042` with `035 JMPUW 055` -- pc-after is 038 (inside
  the handler) and the target 055 is outside it, so the VM really does
  throw and really does run `a.tick` before landing on 055. A bare `goto
  L55` there would silently skip the ensure body. The conservative test
  also keeps `JMPUW` from interacting at all with `RESCUE_SUPPORT`'s own
  region extraction (which lifts a protected range into a separate C++
  function a `goto` could not cross). Measured cost of that conservatism
  against the real whole program: zero -- all 7 sites sit in ireps with no
  catch handlers at all.

  `mruby-rpg2k-compiled/src/register.cxx` gains one required coordinated
  change: `MRB_SET_INSTANCE_TT(interpreter, MRB_TT_DATA)`. With `#update`
  no longer an `#error` stub, every one of the exactly 3 methods that
  touch `Game::Interpreter#@frame_steps` (`#initialize`,
  `#reset_frame_steps`, `#update`) now compiles clean, so bc2cpp's own
  `every_accessor_compiles?` guard finally lets that fixnum ivar embed --
  `Game__Interpreter_ivars` goes from 0 references in the generated output
  to 10, including a real `mrb_calloc` + `mrb_data_init` pair at the top
  of `Game__Interpreter_initialize_impl`. Without the new call that
  `mrb_data_init` would run against an object mruby still allocates as
  `MRB_TT_OBJECT` -- the exact undefined-behavior shape this same file's
  `Game::Actor` and `Game::Transition` blocks already document as two
  separate, previously-shipped live memory-safety bugs. Re-checked by hand
  against every hazard condition those two established (see that call's own
  comment): no native C++ anywhere constructs or type-checks a
  `Game::Interpreter`, the class has no subclass in the closed world, the
  interpreter object is never Marshal'd or ivar-enumerated (the save path
  goes through `Game::State`'s own explicit `#to_h`/`.load` field list),
  every other ivar stays on the dynamic `iv_tbl` that `struct RData`
  carries in its own right, and the `DIRECT_CONSTRUCT_TARGETS` path needs
  no edit because `bc2cpp_direct_alloc` already allocates with
  `mrb_obj_alloc(M, MRB_INSTANCE_TT(c), c)`.

  Verified against the real whole-program diagnostic: compiled entry
  points 2252 -> 2258, method-level coverage 97.1% -> 97.4% (methods left
  on the interpreter 66 -> 60), `unhandled opcode JMPUW` 7 -> 0, total
  `#error` markers 119 -> 112, with no other bucket changing in either
  direction. All 6 methods confirmed present in the real
  `SKIP_UNSUPPORTED=1` shipped output (0 -> 2 symbols each, entry point
  plus `_impl`), and `RPG2k#trim_ini_value`'s own regenerated body
  inspected directly: its `break` is a plain `goto L97;` with the matching
  `L97:;` label emitted, exactly the bytecode's own control flow.
  `scripts/rpg2k_logic_check.rb` (1201 checks),
  `scripts/rpg2k_scene_check.rb` (1062 checks), and
  `scripts/lcf_testbed_check.rb` all still pass unchanged. A real `g++
  -std=c++17 -fsyntax-only` compile of the actual `SKIP_UNSUPPORTED=1`
  generated whole-program output confirms the exact same 17 pre-existing,
  already-documented, unrelated errors as immediately before this change
  and zero new ones (byte-identical error text); `register.cxx` itself,
  compiled against a real cross-gem `OTHER_DECLS_HEADER` wiring, likewise
  shows an identical error set before and after.

  `docs/bc2cpp_coverage.txt`'s dynamic-dispatch statistics block also
  moves here for a reason unrelated to this change: the committed file
  predates the current host mrbc, which emits `OP_NOT`/nil-test shapes the
  older one did not (`:!`, `:!=`, `:nil?` appear; totals shift). Confirmed
  pre-existing by regenerating the report from an otherwise untouched tree
  with the same mrbc -- that block moves identically with no source change
  at all, while the `#error`/coverage blocks above stay byte-identical to
  the committed baseline.
