# 0499. Dispatch-table symbol sets come from the bytecode IR

Date: 2026-10-19

## Status

Accepted

## Context

`SymbolFlow` (tools/bc2cpp/symbol_flow.rb, ADR 0450) proves the finite name set of a constant
dispatch table such as optcarrot's `DISPATCH`, so that yield_reach.rb can record
`send(*TABLE[i])` as calls to those names instead of an unknown call. It walked
`irep.instructions` itself in 23 places, with its own predecessor lists, its own "does this op write
the register" rule and three copies of the P2 escape walk (only the last one was live).

Its consumers:

| Site | Use | Feeds |
| --- | --- | --- |
| tools/bc2cpp/yield_reach.rb `scan_dynamic_send` / `dispatch_send_universe` | `predecessors`, `splat_table`, `dispatch_universes` | codegen: YieldReach decides the yield-free proof (codegen_yield_free.rb) |
| scripts/bc2cpp/symbol_flow_check.rb | `dispatch_universes` | check only |

`ComputedSendNames.names_at` (computed_send_names.rb, ADR 0303), the other computed-send name source,
already reads `BytecodeIR.reaching_definitions`. Its `SymbolTables.analyze` still scans every irep
for SETCONST/CLASS sites, which is constant analysis and is moving to the IR separately (ADR 0493).

Comparing the walk with a reaching-definitions version on fixtures showed that the walk accepted
tables that can hold names it never saw:

- its write rule ignored callee frames and nested-block `SETUPVAR`, and treated a block's entry
  registers as the writer's parameters;
- P2 treated a send whose receiver is the table as a write that ends the path, and did not see the
  table as a send argument (the argument window is not a named operand), as `X::TABLE`, or through
  an element that is then written;
- a SETIDX whose base mixes the table with another value was not counted as a table write, so P3
  never checked what it stores;
- a splat call of the writer counted as arity 0, `push(a, b)` checked only `a`, and other container
  mutators (`concat`, `insert`, ...) were not looked at;
- `splat_table` accepted `send(:x, *TABLE[i])`, whose name is `:x`, as a table send;
- the universe was every `LOADSYM` of the class body and the writer, not the stored names.

## Decision

`IrSymbolFlow` (tools/bc2cpp/ir_symbol_flow.rb) replaces SymbolFlow, with the same API for
yield_reach (`dispatch_universes`, `splat_table`; the predecessor lists are gone).

- Symbol sets propagate along `BytecodeIR.reaching_definitions` with `through_handlers:`, MOVE
  chains followed, the nested-block registers opaque, and the state cap raised to four states per
  instruction so a long class body still answers. A refused query refuses the table.
- Writer parameters get the union of the sets their call sites pass (P4), and the writer's ENTER
  must take exactly that many required parameters.
- Readers of the table come from a forward walk over the IR's successor and handler edges, stopped
  by an op that always writes the register. Reaching definitions cannot answer this direction: a
  send below the register makes them refuse (`:callee_frame_clobber`), while for an escape check the
  value may survive the send, so the walk keeps going. The table may only be the base of GETIDX or
  SETIDX, and an element may only be splatted.
- The constant and the writer must not be spelled as a Symbol or String literal anywhere, and no
  GETMCNST/SETMCNST may name the constant.
- `SETIDX`, `<<` and `push` in the class body and the writer fold their stored values into every
  set; any other container mutator there refuses.

`BC2CPP_IR_SYMBOL_FLOW` selected the new analysis (`1`) or compared the two (`compare`) while both
existed; the switch went away with SymbolFlow.

## Consequences

- On the engine (wio closed world, 4230 ireps) neither analysis proves a table and no splat send
  reads one, so yield_reach and the generated C++ are unchanged there. The IR version takes 1.4 s
  against 31 s for the walk when it runs.
- On optcarrot, `DISPATCH` is no longer proved: `OptimizedCodeBuilder#build_loop` reads it with
  `DISPATCH.map.with_index`, a send on the table that the walk mistook for a write. With that read
  removed, the IR proves 97 names where the walk claimed 137 (the extra 40 were ivar and method
  names that are never stored). ADR 0451 keeps the sealed `CPU#run` interpreted for other reasons, so
  no compiled method is expected to be lost; a sealed optcarrot build was not run to confirm it.
- Remaining limits, unchanged from the walk: a name built at run time and given to `const_get`,
  `send` or `method`, and a container stored in the table that is also passed to a method or is
  nested in a splatted entry. docs/bc2cpp-ir-symbol-flow.md lists them.
- scripts/bc2cpp/symbol_flow_check.rb covers each refused escape and the exact universe, and the
  bc2cpp job now runs it.
