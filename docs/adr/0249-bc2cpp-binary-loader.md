# 249. bc2cpp reads instruction bytes from the RITE binary, not `mrbc -v` text

Date: 2026-09-29

## Status

Accepted

## Context

bc2cpp is meant to compile from a real bytecode IR (ADR 0236). Every pass
already reads operands through typed accessors (`InsnOperands` over
`OperandSchema`), but the loader still produced each `Insn` by parsing the
`mrbc -v` disassembly text and then re-parsing its operand text into typed
operands. That made the text format a load-bearing interface: an unquoted
symbol containing a space, a `\n` in a string literal or a missing line
number silently changed or dropped instructions.

## Decision

`run_mrbc` now runs `mrbc -g -o x.mrb` next to the existing `-B -S` C dump and
returns the RITE binary (`RiteImage`) in place of the disassembly text.
`tools/bc2cpp/rite_binary.rb` reads the irep tree (iseq bytes, catch handler
table, pool, symbols, LV and DBG sections) and `tools/bc2cpp/insn_decoder.rb`
decodes the iseq with the opcode formats of `mruby/ops.h`, including
EXT1/EXT2/EXT3 widening. Typed `OperandSchema::Operand`s are built directly
from the decoded values. `Insn#args` and `Insn#raw` are still synthesized in
`src/codedump.c`'s print format (tab padding, `; R5:name` local-variable
comments, pool comments) because diagnostics and the `// insn` comments in the
generated C++ show them; keeping them identical keeps the generated output
byte-identical.

The C dump is still parsed for the irep metadata (`nlocals`, pool, reps and
labels). `BC2CPP_TEXT_LOADER=1` keeps the text loader as a reference, and
`scripts/bc2cpp_binary_loader_check.rb` proves both loaders yield the same
stream (address, op, typed operands, args, raw, line, file, catch handlers)
for the closed-world gems and a synthetic source that forces EXT widening.

## Consequences

- No pass depends on disassembly text any more; only diagnostics print it.
- Symbol names that the text form could not represent (`:"a b"`) now decode.
- The opcode table is duplicated from `ops.h`; the check compares the two.
- Follow-up: build the whole `Irep` (pool, syms, reps) from the RITE binary
  and retire the C dump regex parse and the text loader.
