# Numeric flow across `break`/`next` (JMPUW_PLAIN)

mrbc compiles the `break` and `next` of a `while` loop (and `redo`/`retry`) to `OP_JMPUW`. `NumericFlow`
(`tools/bc2cpp/numeric_flow.rb`) used to refuse any irep containing one. The flow returned no state for it, so:

- the irep's own arithmetic and compares got no `NUMERIC_OPERAND_PROOF` arms;
- every `SETIV` in it failed its ivar group (`NUMERIC_IVAR_PROOF`), and with it that ivar's proof and class pool
  in every method of the program;
- every `SETCONST` in it failed its constant group in the same way.

The resumable `Optcarrot::PPU#main_loop` ends its scanline loop with `while true ... break`, so it was one of these
ireps. Its stores of `@hclk`, `@scanline` and `@sp_phase` failed those ivars for all of PPU.

## Why a plain JMPUW is a JMP

vm.c's `OP_JMPUW` throws to an ensure handler only when `irep->clen > 0` and an ensure handler covers the jump and
not its target. Otherwise it sets `pc` to the target, exactly like `OP_JMP`. With no catch handler in the irep
(`!program.handlers?`, the test `CodeGen#jmpuw_is_plain_jump?` already uses to compile JMPUW as `goto`), the IR's
successor edge to the target is the only edge. The flow reads the JMPUW as a JMP: it writes no register, and the
IR already lists its target as a successor (`build_edges` uses `branch_target`, which includes JMPUW).

A JMPUW in an irep with a `rescue` or `ensure` stays unsupported, since it may run the ensure body before it
reaches its target. `BC2CPP_NUMERIC_JMPUW=0` leaves every JMPUW irep unmodelled, as before.

## Core-body memos

Modelling more ireps exposed two memos that a core-body compile could poison. `compile_method` compiles mruby's own
Ruby with `@closed_world` withheld, and compile probes run before `compute_numeric_facts`. When a core irep with a
JMPUW was modelled during such a probe, its constant reads called `lexical_const_info` first, which then memoized
the empty closed-world-less analysis for the whole run. Every `NUMCONST` fact of optcarrot disappeared.
`lexical_const_info` and `numeric_nil_raises?` now answer a core body without memoizing.

## Effect on the resumable step function

A resumable step function gets the same proof-driven arms as any other compiled method: no proof code checks
`@resumable`. Its registers are `mrb_value` locals (RESUMABLE_LOCAL_REGISTERS), as in every other method. bc2cpp has
no unboxed `mrb_int` register representation. A Fixnum proof drops a tag test, and GCC removes the boxing in between.

In optcarrot the hot registers of `main_loop` hold `@hclk` and `@hclk_target`, and this change still proves neither:

- `@hclk += 1` reads an ivar whose entry mask includes nil (`reset`, not `initialize`, assigns it). The old
  file-level nil-operator scan listed `+` because `mruby-rational` defines `nil.to_r` next to `Rational#+`. The
  scan now reads each registration's owner and `@hclk` is proven
  ([NIL_NATIVE_ANSWERS](bc2cpp-nil-native-answers.md)).
- `@hclk_target` and `@vclk` are assigned by destructuring the frozen `DUMMY_FRAME`/`BOOT_FRAME` Arrays, and from
  `PPU#sync`'s argument. Neither of those values is typed.
- An Integer proof also covers a bigint. Only a Fixnum interval would drop the tag tests of `@hclk += 1` and
  `@hclk_target <= @hclk`, and a counter that only grows has no such interval.

## Check

`MRBC=path/to/mrbc ruby scripts/bc2cpp/numeric_jmpuw_check.rb` compiles a Fiber root that writes its ivars around a
`while true ... break` and a `next`, a plain method with the same loop shape, and a `break` inside `begin ... ensure`.
It asserts the `NUMIVAR` facts and the `NUMERIC_OPERAND_PROOF` arms in the step function and its inlined helper. It
asserts that the ensure method's ivar stays unproven and that `BC2CPP_NUMERIC_JMPUW=0` drops the facts. It then
compares interpreted and compiled runs, where an Integer overflows to a bigint between two yields, a bigint is held
in a register across a resume, and a Float is stored into a proven ivar.

## Measurement

Optcarrot probe (Lan_Master, callgrind). Instructions per frame are (21 frames − 1 frame) / 20. Both builds come from
the same tree. Checksum `59662` at 180 frames.

| Build | Instructions per frame | 1-frame run (startup) |
| --- | ---: | ---: |
| `BC2CPP_NUMERIC_JMPUW=0` | 26,507,449 | 1,098,898,702 |
| Default | 26,506,883 | 1,098,898,563 |

The generated optcarrot code changes in `APU#reset_mapping` (cold) and in one `@sp_ram[0]` read in `main_loop`, which
now takes the exact-Array path. The change is about soundness coverage. It adds no speed on this workload.
