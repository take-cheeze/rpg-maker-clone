# 0499. Dispatch-table symbol sets come from the bytecode IR

Date: 2026-10-19

## Status

Proposed

## Context

`SymbolFlow` (tools/bc2cpp/symbol_flow.rb, ADR 0450) proves the finite name set of a constant
dispatch table such as optcarrot's `DISPATCH`, so that yield_reach.rb can record
`send(*TABLE[i])` as calls to those names instead of an unknown call. It walks
`irep.instructions` itself in 23 places, with its own predecessor lists, its own "does this op write
the register" rule and three copies of the P2 escape walk (only the last one is live).

Its consumers:

| Site | Use | Feeds |
| --- | --- | --- |
| tools/bc2cpp/yield_reach.rb `scan_dynamic_send` / `dispatch_send_universe` | `SymbolFlow.predecessors`, `splat_table`, `dispatch_universes` | codegen: YieldReach decides the yield-free proof (codegen_yield_free.rb) |
| scripts/bc2cpp/symbol_flow_check.rb | `dispatch_universes` | check only |

`ComputedSendNames.names_at` (computed_send_names.rb, ADR 0303), the other computed-send name source,
already reads `BytecodeIR.reaching_definitions`. Its `SymbolTables.analyze` still scans every irep
for SETCONST/CLASS sites, which is constant analysis and is moving to the IR separately (ADR 0493).

## Decision

Re-express SymbolFlow on the IR (stage 2 behind `BC2CPP_IR_SYMBOL_FLOW`, then the only
implementation): values propagate along `BytecodeIR.reaching_definitions`, and the escape check
walks the IR's successor and handler edges.

## Consequences

To be filled in when the change lands.
