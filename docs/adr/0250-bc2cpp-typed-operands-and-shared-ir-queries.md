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

## Addendum: catch-handler edges

`tools/bc2cpp/bytecode_ir_handlers.rb` models exception flow beside, not inside,
the normal-flow graph. Each instruction in a handler's half-open `[begin, end)`
gets a kind-tagged (`:rescue`/`:ensure`) edge to the handler target;
`instruction_predecessors(include_handlers: true)`, `successors_of`,
`reachable_from`, `dominates?` and `every_path_reaches?` opt in. The edge set
over-approximates (extra edges only cost proofs) and does not model an
exception leaving the frame uncaught, so `every_path_reaches?` judges exits on
normal flow. `Instruction#successors` and the blocks stay normal-only.

The fixnum proof and the rescue recognizer now take their handler-derived sets
(target addresses, protected addresses, partial-overlap test) from the IR; the
barriers themselves are unchanged, so accept/reject decisions are identical.

## Addendum: barrier shadow (not migrated)

The Fixnum proof and return analysis refuse on two exception-flow sets:
`ctx[:catch_targets]` (handler targets) and `ctx[:protected]` (handler ranges,
end address included). `tools/bc2cpp/fixnum_barrier_shadow.rb` re-derives both
from handler edges (edge targets; edge sources plus the instruction at each
range end) and re-runs every barrier consumer with them swapped in.
`scripts/bc2cpp_barrier_shadow_report.rb` runs it on the real closed-world wio
build: 2405 irep contexts and 157431 queries, zero differences, generated
output unchanged.

The barriers stay as they are. Equality holds on the shipped gems only because
they have no handler of these shapes; for arbitrary bytecode the edge-derived
sets differ, always toward accepting more (unsafe):

- a handler whose target is not an instruction has no edges, so its range is no
  longer protected;
- a handler whose range holds no instruction has no edge, so its target is no
  longer a catch target.

Making them equal needs the handler ranges and declared targets themselves,
which is what `handler_target_addrs` / `handler_protected_addrs` already are
(IR queries over `catch_handlers`), so an edge-based rewrite would add rules
without removing a hand-written computation.
