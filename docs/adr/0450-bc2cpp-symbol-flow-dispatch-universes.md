# 0450. Finite symbol universes for constant dispatch tables in bc2cpp

Date: 2026-10-15

## Status

Accepted

## Context

yield_reach.rb decides which methods a Fiber body can reach, and therefore which calls may
yield. A dynamic send such as `send(*TABLE[i])` names its target only at run time, so the
analysis must assume it may reach any method. In optcarrot, `CPU#run` dispatches opcodes through
`send(*DISPATCH[@opcode])`, where `DISPATCH` is a constant table built in `op`. The unknown send
made `CPU#run` unprovable as yield-free, so the closed-world (sealed) build left it interpreted:
about 13 fps, against about 35 fps for the default bc2cpp build.

The table's contents are known at compile time only if the program stores literal symbols into
it and nothing else can write it. Without a proof of that, treating the table's symbols as a
finite set would be unsound: an alias or a runtime-created symbol could add a method the analysis
never saw.

## Decision

`SymbolFlow.dispatch_universes` (tools/bc2cpp/symbol_flow.rb) returns, for each constant whose
premises hold, the finite set of symbol names the constant's table can contain. yield_reach.rb
records a dispatch send through such a table as calls to exactly those names. Constants whose
premises do not hold keep the unknown-call treatment.

The premises are checked on the bytecode, and each one is needed for soundness:

- P1: one SETCONST, in the class-body irep, and all SETIDX stores into the constant in one writer
  method (possibly inside its blocks).
- P2: GETCONST values are used only as the base of GETIDX or SETIDX on every path, so no alias
  can write the table unseen.
- P3: every stored value is literal along every path that reaches the store.
- P4: every call of the writer is by name, in the class irep, with one arity and literal
  arguments, so the writer's parameters are literal and never rewritten.
- P5: the class irep and the writer create no symbol at run time (INTERN, `to_sym`, `intern`).

The universe is every LOADSYM symbol in the class irep and the writer's irep. That covers every
symbol P3 allows into the table. The premises are exercised by scripts/bc2cpp/symbol_flow_check.rb,
which accepts a literal table and rejects a runtime `to_sym`, a send-result store, and a second
writer.

Dispatch sends that do not match this shape (for example `send(*X)` where `X` is a parameter or a
send result) still take the unknown-call treatment.

## Consequences

- Constant dispatch tables such as optcarrot's `DISPATCH` (137 symbols) no longer force
  unknown-call treatment, which removes one cause of the `CPU#run` refusal.
- The analysis is only as sound as the five premises. Any change to how SETIDX, GETCONST, or
  symbol creation are compiled must be checked against P1 through P5 again.
- Other unknown sends still block `CPU#run`. Those are the `event` dispatch fed by literal
  callers in driver.rb, the `parse_option` return flow through `find_option`, and an unnamed
  `SEND` with n=2. Resolving them is follow-up work; this ADR does not claim the sealed build is
  faster yet.
