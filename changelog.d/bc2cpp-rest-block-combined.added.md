- `tools/bc2cpp/bc2cpp.rb` can now compile a method declaring BOTH a real
  `*rest` positional parameter AND a real named block parameter in the same
  signature -- `def method_missing(name, *args, &block); @io.__send__(name,
  *args, &block); end` (`RGSS::ErrorReport::Tee`, the last remaining "has
  non-mandatory arguments" bucket entry) -- previously an honest `#error`
  outright, since `REST_ARG_SUPPORT` and `EXPLICIT_BLOCK_PARAM_SUPPORT` each
  required the other's own ENTER field to be zero.

  Confirmed via a fresh `mrbc -v` disassembly (`ENTER 1:0:1:0:0:0:1:0`) that
  the real block value simply arrives one register further along than the
  plain block-only case: at `mand+rest+1` (here R3, since mand=1/rest=1),
  copied by a plain `MOVE` into whatever local name mrbc chose -- exactly
  `total_args + 1` once `total_args` already includes the rest slot, the
  same formula `EXPLICIT_BLOCK_PARAM_SUPPORT`'s own register-init write
  already used (`mand + 1` was simply the `total_args == mand`, no-rest
  special case of this same formula). `rest_only_arity?`/`block_param_arity?`
  each dropped the other's own zero-field requirement; unlike
  `OPTIONAL_KEYWORD_COMBINED_SUPPORT`'s own jump-table recognition, neither
  ENTER field needs any separate bytecode-shape validation of its own (both
  are pure ENTER-field facts, the real register position follows
  mechanically), so no defensive "did the other half actually resolve"
  guard was needed here. The entry wrapper's own `elsif has_rest` branch
  gained the same `&` format-string marker and `bc2cpp_blk` extraction/
  trailing call argument `EXPLICIT_BLOCK_PARAM_SUPPORT`'s own plain branch
  already established -- `*` (rest) and `&` (block) are independent
  `mrb_get_args` format specifiers, safe to combine on the same call.

  Fixing the method's own arity gate revealed a SEPARATE, genuinely
  different gap in its own body: `@io.__send__(name, *args, &block)` is a
  positional splat (`n=*`) combined with `&block` -- a shape
  `EXPLICIT_BLOCK_ARG_SUPPORT`'s own recognizer never matched (its `n_match`
  regex required a literal digit count, `n=*` failed to match at all,
  falling through to the honest `#error unhandled opcode SENDB`).
  Confirmed via the same disassembly that the real args Array is already
  fully built into `R(dest+1)` by the time this `SENDB` runs -- the exact
  same `ARRAY`/`LOADNIL`-then-`ARYCAT` guarantee `compile_dynamic_splat_
  send`'s own comment already established for the non-`&expr` case -- with
  the block's own value simply sitting in the next register, `R(dest+2)`.
  `recognize_explicit_block_arg_regions`/`emit_explicit_block_arg_glue`
  both gained this `n == '*'` case, forwarding via `RARRAY_LEN`/
  `RARRAY_PTR` straight into `mrb_funcall_with_block` -- the same shape
  `compile_dynamic_splat_send`'s own `mrb_funcall_argv` call already
  trusts, just with a real block argument instead of none.

  Verified against the real whole-program diagnostic: compiled entry
  points 2247 -> 2248, method-level coverage 96.9% (rounds the same, real
  count 71 -> 70 left on the interpreter), "has non-mandatory arguments"
  bucket now empty (the last entry, `RGSS::ErrorReport::Tee#method_missing`,
  gone), total `#error` markers 126 -> 125. `scripts/rpg2k_logic_check.rb`
  (1201 checks), `scripts/rpg2k_scene_check.rb` (1062 checks), and
  `scripts/lcf_testbed_check.rb` all still pass unchanged. Directly
  inspected real generated output: `bc2cpp_blk` correctly lands in R3 (the
  real `MOVE R4 R3` target), and the `__send__` call correctly forwards
  both the built args Array and the block through `mrb_funcall_with_block`.
  A real `g++ -std=c++17 -fsyntax-only` compile of the actual
  `SKIP_UNSUPPORTED=1` generated output confirms the exact same 17
  pre-existing, already-documented, unrelated errors as immediately before
  this change and zero new ones.
