# 250. bc2cpp reads typed operands and shares its IR queries

Date: 2026-09-29

## Status

Accepted

## Context

ADR 0236 set the goal that bc2cpp compiles from a real bytecode IR. In practice
every pass still recovered facts from the instruction's operand *text* with its
own regex (`args[/^R(\d+)/, 1]`, `args.split.last`, ...): about 450 call sites
in 30 files. That was fragile in ways the generated code could not reveal. A
trailing `; R5:name` disassembly comment was read as the jump operand, so
`constant_object_owner` and `BytecodeIR` lost the branch edge after any
keyword-argument prologue and calls such as `LCF.field?` stayed dynamic. Five
copies of the "branch target of an instruction" case statement, three
predecessor/edge builders and about forty backward register scans had drifted
apart, and two control-flow graphs disagreed about `JMPUW` and `RAISE`.

## Decision

- **One schema.** `tools/bc2cpp/operand_schema.rb` lists, for every opcode of
  `mruby/ops.h`, the kinds of its operands in print order (register, `(R)`
  register, symbol, pool/irep index, integer, address, `n=|nk=` argument
  count, `ENTER`/`ARGARY` field groups, ...). An instruction is parsed once, at
  load, into typed `Operand` values; an instruction the schema cannot parse
  raises instead of answering `nil` to every question.
- **Typed accessors only.** `InsnOperands` (`reg`, `regs`, `sym`, `ivar`,
  `argc`, `n_spec`/`nk_spec`, `block_index`, `const_name`, `branch_target`,
  `upvar_ref`, `enter_fields`, ...) is a lookup by operand kind. No pass reads
  `Insn#args`; it survives only for diagnostics and generated-code comments.
  Compiler-built instructions use `Insn.synthetic`.
- **One control-flow graph.** `BytecodeIR` builds successors, predecessors and
  basic blocks once. It models `JMPUW` and the `RET*` ops, keeps `RAISE` and
  `RAISEIF` falling through (an extra predecessor only costs a proof, a
  missing one gives a wrong answer), and flags jumps to non-instructions as
  unresolved. The Fixnum proof, the rescue/ensure recognizers and the loop
  region recognizers read it.
- **Shared scans.** `Irep#last_writer`, `#source_writer`, `#index_of_addr`,
  `#instructions_at` and the `IrepScans` walk primitives answer
  reaching-definition and address-range questions in one place, with explicit
  options for the per-site differences (skipped ops, barriers, `.freeze`
  continuation).
- **Verification.** `bc2cpp_operand_schema_check.rb` parses and round-trips
  every instruction of the closed-world gems against the schema. Every
  migration step was accepted only if the generated C++ and diagnostics of a
  full closed-world build were byte-identical to the pre-migration output.

## Consequences

- Text-format quirks can no longer change compiler behaviour; a new opcode form
  fails loudly at load.
- Analyses that previously had to guess at operand shapes can ask the IR, which
  is what the dispatch-elimination work needs (the branch-comment bug alone
  removed five dynamic sends).
- Adding an opcode or a new `mrbc` print form means updating the schema table;
  the schema check names the instruction that does not fit.
- The one remaining text-derived surface is `Insn#args`/`#raw`, kept so
  generated comments stay identical; ADR 0249 moves the loader itself off text.
