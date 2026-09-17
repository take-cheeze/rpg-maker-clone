- `tools/bc2cpp/bc2cpp.rb` can now compile real Ruby `&expr` explicit-
  block-argument call sites -- `ary.reject(&:out_of_play?)`,
  `ary.each(&method(:handler))`, `ary.map(&proc_var)` -- previously an
  honest `#error unhandled opcode SENDB`/`SSENDB` regardless of how
  simple `expr` was.

  Confirmed via a fresh `mrbc -v` run (not assumed) that `&expr` compiles
  to a COMPLETELY DIFFERENT bytecode shape than a literal `{ }`/
  `do...end` block: `expr` is evaluated as an ordinary value straight
  into `R(dest+n+1)`, with NO `BLOCK` instruction anywhere before the
  `SENDB`/`SSENDB`. Every existing block-carrying-call recognizer in this
  file (BLOCK_FALLBACK included) gates on a `BLOCK` instruction
  immediately preceding the call, so this entire shape fell through to
  the raw opcode-level `#error` unconditionally.

  No block BODY exists to compile here at all -- `expr` is just whatever
  value `&` was applied to, already sitting in a register -- so the new
  `recognize_explicit_block_arg_regions`/`emit_explicit_block_arg_glue`
  needs none of `BLOCK_CFUNC_FALLBACK_SUPPORT`'s machinery (no standalone
  cfunc, no RProc construction, no self/upvar capture): real `mrb_funcall_
  with_block` (3rd/mruby/src/vm.c) already calls `ensure_block` on
  whatever it's handed -- `if (!mrb_nil_p(blk) && !mrb_proc_p(blk)) blk =
  mrb_type_convert(mrb, blk, MRB_TT_PROC, MRB_SYM(to_proc));` -- the exact
  real `#to_proc` coercion a Symbol/Method/any `&`-able object needs, with
  a real `nil` (`&nil`) passing straight through unchanged. So the whole
  translation just hands that register straight to `mrb_funcall_with_block`
  in place of the RProc `emit_block_fallback_glue` builds -- same
  `try`/`catch (bc2cpp_block_break&)` wrapping (a forwarded Proc might
  itself be one of this program's own BLOCK_FALLBACK-compiled RProcs).
  Composes with nested BLOCK_FALLBACK bodies too (`emit_proc_fallback_fn`'s
  own recursive pass now also recognizes this shape inside a block's own
  body), though no real whole-program site needs that today.

  Verified against the real whole-program diagnostic: compiled entry
  points 2204 -> 2213, method-level coverage 95.0% -> 95.4%, `#error
  unhandled opcode SENDB` 80 -> 68, total `#error` markers 227 -> 215.
  `scripts/rpg2k_logic_check.rb` (1201 checks), `scripts/rpg2k_scene_check.rb`
  (1062 checks), and `scripts/lcf_testbed_check.rb` all still pass
  unchanged. Directly inspected real generated output:
  `(@allies + @enemies).reject(&:out_of_play?)` correctly forwards the
  literal `:out_of_play?` Symbol straight into `mrb_funcall_with_block`.
  32 real whole-program call sites take this new path. A real
  `g++ -std=c++17 -fsyntax-only` compile of the actual `SKIP_UNSUPPORTED=1`
  generated output confirms the exact same 17 pre-existing,
  already-documented, unrelated errors as immediately before this change
  (only their line numbers shifted) and zero new ones.
