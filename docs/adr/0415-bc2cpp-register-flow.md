# 0415. bc2cpp register flow: copy propagation and dead register writes

Date: 2026-10-12

## Status

Accepted

## Context

A compiled method keeps every bytecode register as a C++ local `rN`, and the
code for one instruction is a self-contained piece of text that names the
registers it reads and writes. mrbc's register allocation leaves many
`rN = rM;` copies, `rN = mrb_nil_value();` initialisers that the next write
overwrites, and `LOADx` writes nobody reads. A 12-line peephole window finds
only a few dozen of them; whether a write is dead is a question about the
whole control-flow graph.

The bytecode IR (`BytecodeIR`, ADR 0198/0261) already provides a conservative
CFG and reaching definitions, but not liveness, and the IR alone is not enough
to rewrite generated code: codegen fuses and suppresses instructions, inlines
blocks and emits its own helper locals, so which registers an instruction
really touches is only known from the text it emitted.

## Decision

`tools/bc2cpp/register_flow.rb` (`RegisterFlow`) runs once per ordinary
compiled method, after every instruction text has been produced and before
the texts are joined. Kill switch: `BC2CPP_REGISTER_FLOW=0` (output is then
byte-identical to before this change). `BC2CPP_REGISTER_FLOW_STATS=1` prints
counters at exit.

* **Defs and uses come from the emitted text.** A text of the exact shape
  `  rD = <expression without ; { } " = goto return throw>;` defines `rD` and
  reads the registers in the expression. Any other text reads every register
  it names and defines none, so an unfamiliar or fused text can only lose an
  optimisation. The CFG is `BytecodeIR`'s; an instruction that emitted nothing
  also falls through to the next text, because its jump or return left no code.
* **Dead write removal.** A backward liveness fixpoint over bitmasks. Only a
  pure write is removed: `MOVE`, `LOADL`, `LOADSYM`, `LOADNIL`, `LOADSELF`,
  `LOADTRUE`, `LOADFALSE` and `LOADI*`, and only when the register is not live
  after it. Removal repeats until nothing more dies.
* **Copy propagation.** For `rD = rS;` every later reader of `rD` is rewritten
  to read `rS` when each reader is a plain-operand op (`MOVE`, `RETURN`,
  `JMPIF/JMPNOT/JMPNIL`, `SETIV/SETGV/SETCV/SETCONST`), the copy is available
  on every path from the entry to the reader (checked backwards through the
  predecessors, stopping at the copy), and neither register is written after
  the copy. If the copy then has no reader the liveness pass removes it.
  Window consumers (`SEND`, `ARRAY`, `ADD`, `HASH`, ...) are not rewritten by
  default: their text writes registers next to the ones it reads, and a copy
  feeding an argument window is the case most worth keeping unproven.
  `BC2CPP_REGISTER_FLOW_WINDOWS=1` is an experimental, default-off switch that
  also rewrites reads inside them (the same text and availability checks
  apply); it is exercised by `register_flow_check.rb` only.
* **The pass refuses a whole method** (texts returned untouched) when the CFG
  is unresolved (`Program#resolved?`), the method has a catch handler (rescue
  and ensure rewrite registers through their own glue), the method is
  resumable, a text declares a reference or captures by reference, a `goto`
  lands anywhere the IR does not allow (a label the same text defines, or a
  successor reached through texts that emitted nothing), an op the IR says never
  falls through emits text that does, or a nested block uses `ARGARY`.
* **Pinned registers** are never removed, substituted or substituted for:
  `r0`, registers a nested block reads or writes by upvar (`GETUPVAR` /
  `SETUPVAR` of any descendant, level matched), registers whose address is
  taken (`&rN`, which is how `BLOCK_FALLBACK` bodies and inlined loops receive
  upvars) and registers redeclared inside a text. Pinned registers are live
  everywhere.
* Block-fallback bodies, other block functions and resumable step functions are
  not touched.

## Consequences

Generated C++ shrinks without changing evaluation order, side effects or
argument windows: the pass edits only register-to-register copies and constant
loads that nothing reads. The follow-up `drop_unused_nil_registers` (see
`docs/bc2cpp-register-output.md`) removes the declarations that become unused.

The soundness argument rests on the text being the ground truth of what runs
(registers are separate C++ locals, so a window cannot be indexed past its
named members) and on the only aliasing channels being `&rN`, reference
declarations and closure capture, which pin or refuse. A new codegen feature
that reads a register without naming it, or passes `rN` by non-const reference
without `&`, would break that premise; `scripts/bc2cpp/register_flow_check.rb`
holds the refusal cases and a compiled-versus-interpreted run.

Liveness is per method and flow-sensitive but does not look into callees, and
the pass cannot touch values that feed argument windows, so the gain is
modest. Measured numbers are in `docs/bc2cpp-register-output.md`.
