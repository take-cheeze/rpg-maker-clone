# Inlined Kernel#loop (KERNEL_LOOP_INLINE)

`loop do ... end` with a literal block is compiled as a `for (;;)` over the block body
(`tools/bc2cpp/codegen_kernel_loop.rb`), one more INLINE_LOOP_PASSES entry. Before, the block became a BLOCK_FALLBACK
cfunc handed to the compiled Kernel#loop, and its `break` was a C++ `throw` caught at the call site. Each `break`
unwound through the C++ personality routine and the frame-descriptor lookup: `LCF.read_ber` breaks once per BER
integer, so loading Nepheshel's database and first map threw about 62,000 times.

## What the inlined loop keeps

Kernel#loop (`3rd/mruby/mrblib/kernel.rb`) is `while true; yield; end` under `rescue StopIteration => e; e.result`.

- `break` and `break value` jump past the loop and leave the value in the send's destination; `next` jumps to the end of
  the iteration. A `return` in the body returns from the method, as in every inlined loop body.
- The body runs under its own `mrb_jmpbuf`. An mruby exception raised in it reaches `bc2cpp_loop_rescue`: a
  StopIteration (from `raise StopIteration` or an exhausted `Enumerator#next`) pops the callinfo frames the raise left,
  as `mrb_protect_error` does, and the loop's value is its `result`. Anything else, a VM break object included, is
  thrown on to the jmpbuf the loop found, untouched.
- `bc2cpp_jmp_restore` restores `M->jmp` on every way out: the goto past the loop, a method return, or a foreign C++
  throw (a block break or return aimed at an outer frame).

## When it applies

- The call is an implicit-self `loop` with a literal block of no parameters that does not read the method's block.
- `block_core_kernel_definition('loop', 0)` proves mruby's Kernel body is the program's only `loop`: no program,
  native or outside definition, no installer, and no BasicObject subclass (`codegen_block_core_direct.rb`, the proof
  BLOCK_CORE_DIRECT uses).
- The method is not a resumable step function.
- Not inlined: a loop inside `begin`/`rescue`, and a body whose own nested block breaks. Those keep the call.

`BC2CPP_KERNEL_LOOP=0` keeps every call. `scripts/bc2cpp/kernel_loop_check.rb` checks the generated sites and runs every
exit of the loop interpreted and compiled.

## Measured

On the headless Nepheshel host ([trace host](bc2cpp-trace-host.md), a `BC2CPP_CLOSED_OPTIMIZE=1` closed build),
callgrind instructions, with CONST_SITE_CACHE's reopened-module rule in both columns:

| Run | Before | After |
| --- | ---: | ---: |
| 1 frame (boot, title, New Game, first map) | 2.89 G | 0.33 G |
| 1,200 frames with a played battle | 5.14 G | 1.74 G |

Nearly all of the difference is the C++ unwinder (`_Unwind_Find_FDE`, `__gxx_personality_v0` and the frame lookup).
The 1,200-frame run's wall time, from master to both changes, went from about 0.46 s to 0.13 s, with the same
output.
