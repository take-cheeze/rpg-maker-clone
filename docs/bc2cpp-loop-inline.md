# bc2cpp: `loop do ... end` as an inlined loop

`LOOP_INLINE` (`recognize_loop_regions` in `tools/bc2cpp/codegen_loop_regions.rb`, `emit_loop_inline` in
`tools/bc2cpp/codegen_loop_inline.rb`) compiles `loop do BODY end` to a native `for (;;)` in the method body. Without
it the site calls the compiled `Kernel#loop` with the block as a C proc. Each `break` then throws
`bc2cpp_block_break`, a C++ exception unwound through `Kernel#loop` back to the call site's catch. Inlined, `break`
is a jump past the loop that leaves its value in the call's destination. `next` is a jump to the next iteration, and
a `return` leaves the method, as in the other inlined loops (`#each`, `#times`).

## When a site is inlined

- **The call is `loop` on self (`SSENDB :loop`) with a literal block.** The block takes no parameter and does not
  forward the method's own block.
- **`loop` is Kernel#loop everywhere.** No program or core class defines another `loop`.
- **Kernel#loop's `rescue StopIteration` never fires.** mruby's `loop` is `while true; yield; end` with
  `rescue StopIteration => e; e.result` (`3rd/mruby/mrblib/kernel.rb`). The inlined loop keeps no rescue, so the pass
  needs a whole-program proof that no StopIteration reaches a loop body. Core Ruby starts one only in
  `Enumerator#next` / `#peek` / `#next_values` / `#peek_values` and inside a Lazy enumerator, and rescues the ones it
  raises itself (`enumerator.rb`, `lazy.rb`). So no program irep may send `next`, `peek`, `next_values`,
  `peek_values` or `lazy`, or read `StopIteration` other than as the class a `rescue` tests
  (`loop_inline_world_safe?`). The RPG2000/2003 engine sends none.
- **The body inlines like any other loop body** (`compile_inline_block_body`). A body with an `ensure`, or a block
  nested in it that itself `break`s (another `loop`, for example), keeps the call.

## Switch and check

`BC2CPP_LOOP_INLINE=0` keeps every site as a call. `scripts/bc2cpp/loop_inline_check.rb` asserts:

- **Inlined:** break with and without a value, `next`, `return` from the block, and a raise.
- **Kept as calls:** a block parameter, a program that sends `Enumerator#next`, a program-defined `loop`, and the
  kill switch.
- **Parity:** interpreted and compiled runs agree, nested loops and an `ensure` included.
