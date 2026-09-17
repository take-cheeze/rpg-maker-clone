- `tools/bc2cpp/bc2cpp.rb`'s `BLOCK_FALLBACK` mechanism can now compile a
  block that uses a real `return` (`RETURN_BLK`) -- the deferred half of
  the `break` work (see `bc2cpp-block-fallback-break-exception.added.md`):
  unlike `break`, which only needs to unwind back to the `SENDB`/`SSENDB`
  call site, a real `return` inside a block exits the whole ENCLOSING
  METHOD, potentially past however much of that method's own body sits
  between the call site and its own top-level entry point (another
  inlined loop, another `BLOCK_FALLBACK` region, ...).

  Reuses the identical `throw`/`catch` mechanism, just with a second,
  distinct carrier type (`struct bc2cpp_method_return { mrb_value value;
  };`, emitted unconditionally alongside `bc2cpp_block_break`) caught at
  a different point: `compile_method`'s own top-level function body is
  now wrapped in `try { <whole body> } catch (bc2cpp_method_return& e) {
  return e.value; }`, but ONLY for a method whose own `BLOCK_FALLBACK`
  regions actually contain a real `RETURN_BLK` (`needs_return_catch`, a
  pre-scan computed once at the very start of `compile_method` -- a pure
  function of the method's own irep, reusing the exact same
  `recognize_block_fallback_regions` result the real region-processing
  loop consumes later, one computation not two that could drift apart).
  Every other method (the overwhelming majority) gets no wrapper at all.
  `emit_block_fallback_glue`'s own per-call-site `catch (bc2cpp_block_break&)`
  needs no change to coexist with this: C++ catch-type matching is exact,
  so a thrown `bc2cpp_method_return` structurally cannot match that
  clause and passes straight through it, unwinding further out to
  whichever enclosing `try` actually catches its own type -- confirmed in
  real generated output, not just reasoned about (see Verification).

  Same safety argument as `break` (`BLOCK_FALLBACK_UNSAFE_OPS`'s own
  `EXCEPTION_BREAK_SUPPORT` comment): this project already builds mruby
  itself with `MRB_USE_CXX_EXCEPTION` project-wide, so a C++ exception
  thrown here and propagating up through `mrb_funcall_with_block`'s own
  real internals (and, in this case, through an inlined loop's own C++
  `for`/`goto` structure and back out to the enclosing method's own
  top-level `try`) unwinds through frames that are already built for
  exactly this.

  Verified against the real whole-program diagnostic: compiled entry
  points 2130 -> 2141 (+11 fully clean), method-level coverage 92.0% ->
  92.5%, `#error unhandled opcode BLOCK` 161 -> 150, `SENDB` 142 -> 137,
  `SSENDB` 32 -> 26, total `#error` markers 412 -> 390, `BLOCK_FALLBACK`
  sites 181 -> 192. `scripts/rpg2k_logic_check.rb` (1201 checks),
  `scripts/rpg2k_scene_check.rb` (1062 checks), and
  `scripts/lcf_testbed_check.rb` all still pass unchanged. Directly
  inspected real generated output for a genuine, non-trivial multi-level
  case: `Game::Battle#step`'s own `loop { ... return ... }` (several real
  early `return`s inside the loop body, from `Game::Battle#step_action`'s
  own real combat-turn-skip logic). The generated
  `Game__Battle_step_impl` wraps its WHOLE body in
  `try { ... } catch (bc2cpp_method_return& bc2cpp_ret) { return
  bc2cpp_ret.value; }`; nested inside that, the `loop` call site's own
  `try { ...mrb_funcall_with_block(...)... } catch (bc2cpp_block_break&
  bc2cpp_brk) { ... }`; and the block body itself
  (`Game__Battle_step_block_fallback_22_impl`) throwing
  `bc2cpp_method_return{r5}`/`{r4}` at several real early-exit points --
  exactly the intended nesting, each exception type passing straight
  through the OTHER catch clause and being caught only by its own real
  match. Real `g++ -std=c++17 -fsyntax-only` compile of the actual
  `SKIP_UNSUPPORTED=1` generated output confirms zero new errors and,
  specifically, zero errors mentioning `bc2cpp_method_return` at all --
  the same 4 pre-existing, already-documented, unrelated categories as
  the two preceding rounds.

  Also added `loop` and `each_char` to `BLOCK_FALLBACK_UPVAR_SAFE_METHODS`
  (the allowlist gating pointer-based upvar capture to methods confirmed
  synchronous by reading their own real body -- see that constant's own
  comment): `loop` (3rd/mruby/mrblib/kernel.rb) is a plain `while true;
  yield; end rescue StopIteration => e; e.result end`, and its own
  `rescue StopIteration` is itself real evidence this whole exception
  mechanism is safe even inside a method that already uses mruby's own
  rescue machinery -- `MRB_CATCH` (3rd/mruby/include/mruby/throw.h)
  expands to a type-specific `catch(mrb_jmpbuf *e)` under
  `MRB_USE_CXX_EXCEPTION`, confirmed by reading the header, never a
  catch-all, so neither `bc2cpp_block_break` nor `bc2cpp_method_return`
  thrown from inside `loop`'s own `yield` can ever be mistakenly caught
  by that `rescue StopIteration`. `each_char`
  (3rd/mruby/mrbgems/mruby-string-ext/mrblib/string.rb) is a plain `while
  pos < self.size; block.call(self[pos]); pos += 1; end`, the same
  synchronous shape as every other entry already on the list.
