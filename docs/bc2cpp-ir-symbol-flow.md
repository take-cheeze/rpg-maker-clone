# Dispatch-table name sets on the bytecode IR

`send(*TABLE[i])` names its method at run time, so yield_reach.rb has to treat it as a call to any
method unless it can prove which names the table holds. `IrSymbolFlow`
(`tools/bc2cpp/ir_symbol_flow.rb`, ADR 0450, ADR 0499) proves that set for a constant table that is
filled with literal entries by one class-level writer method, such as optcarrot's `DISPATCH` built
by `CPU.op`.

## How the set is found

- **Values** propagate along `BytecodeIR.reaching_definitions` (handler edges included, MOVE chains
  followed). The set of a register at a read is the union over the definitions that reach it:
  `LOADSYM` adds its name, other literal loads add nothing, `ARRAY`/`HASH`/`ARYCAT`/`ARYPUSH`/
  `HASHADD` take the union of their elements, `GETIDX`/`AREF` take their container's set, a
  `GETCONST` of a literal constant of the class takes that constant's set, and a `GETUPVAR` takes
  every write of the captured register. Anything else, including a refused query, makes the set
  unknown and the table is not proved.
- **Writer parameters** get the union of the sets their call sites pass. Every call of the writer
  must be in the class body, with one plain arity that the writer takes as required parameters only.
- **Mutations** in the class body and the writer (`SETIDX`, `<<`, `push`) fold their stored values
  into every set. Any other container mutator there (`concat`, `insert`, `[]=`, ...), and any
  `to_sym`/`intern`/`INTERN`, refuses the table.
- **Readers** of the table come from a forward walk over the IR's successor and handler edges from
  each `GETCONST`, stopped by an op that always writes the register. The table may only be the base
  of `GETIDX` or `SETIDX`; an element `GETIDX` reads may only be splatted (`ARYCAT`). A table that is
  a send's argument or receiver, is moved, is captured by a block, is named as `X::TABLE`, or whose
  name or writer's name appears as a Symbol or String literal anywhere, is refused.

The universe is the union of the stored values' sets, so names that only appear elsewhere in the
class body are no longer included.

## Flat factory work stacks

`FactoryFlow.uses` follows `MOVE` aliases over normal and handler edges with a flat work
stack: each entry pushes its origin and register separately, and visited states are tracked
per origin, so no per-state pair Array is built for traversal or duplicate suppression.
LIFO order, duplicate suppression, result insertion order and the alias-budget refusal match
the pair-based walk. Returned use pairs keep their representation, and ordered results
compare equal, not just as Sets. The struct-receiver check covers entry reuse order, budgets
at and below the visited-state count, loops, `MOVE` aliases, handler reads and overwrites.

Two serial warm-cache Ruby 4.0.5/YJIT whole-engine comparisons reduced allocations from
68,332,683 to 68,130,207 (202,476 fewer, 0.30%) and from 68,333,890 to 68,130,686
(203,204 fewer, 0.30%). Generated C++ and diagnostic logs matched after checkout-root
and timing-line normalization. Wall time moved 48.096s to 48.880s and 49.450s to
49.760s; these runs do not establish a stable elapsed-time gain.

## What it does not cover

- A name built at run time and passed to `const_get`, `send` or `method` can still reach the table
  or the writer. The spelled-name rule only catches literals.
- A container stored in the table and also passed to a method (or splatted as an argument) can be
  mutated by that method. A dispatched method can mutate an entry's nested containers.

These are the same limits the raw-instruction walk had. See ADR 0499 for the escapes it missed that
this one refuses.

## Checking it

`MRBC=path/to/mrbc ruby scripts/bc2cpp/symbol_flow_check.rb` compiles fixture programs and checks
the exact universe of a literal table, each premise's refusal and each escape (an argument, a
receiver, `Cpu::TABLE`, a written element, the writer named as data, a `concat` entry, a splat
writer call and `send(:x, *TABLE[i])`). The bc2cpp job runs it.

## Instruction-read reuse

When following different values through one body, `value_reads_compute` reuses a
frozen read-register list for each visited instruction. The cache belongs to that
body's immutable `BytecodeIR::Program`, is indexed by instruction position, and
is bounded by the instruction count. It does not cache a value walk, alias
budget, handler decision or captured-register decision. Equal labels in different
bodies cannot share this metadata.

`BC2CPP_SYMBOL_READS_CACHE=0` restores reconstruction of the read lists for
comparison. The public `reads` helper still returns its ordinary result. Existing
value-query caching is independent. The bytecode and register count must remain
unchanged while its Program is in use, as required by the other IR caches.

`symbol_flow_check.rb` covers distinct origins, frozen instruction-aligned lists,
body isolation and repeated-walk allocation counts, comparing query results with
the instruction cache disabled. Existing factory and dynamic-name fixtures check
normal/handler flow and conservative refusals.

Two alternating warm-cache comparisons on Ruby 4.0.5 + YJIT, using the desktop
closed whole-engine source set with all compiled owners and hot-only disabled:

| Run | Baseline wall | Read-cache wall | Baseline objects | Read-cache objects |
| --- | ---: | ---: | ---: | ---: |
| 1 | 49.668 s | 49.206 s | 75,292,525 | 72,644,169 |
| 2 | 48.871 s | 48.937 s | 75,292,584 | 72,644,377 |

This removes about 2.65 million allocations per generation (3.52%). The timing
changes go in opposite directions, so these local runs do not demonstrate a
consistent elapsed-time improvement. Generated C++ and diagnostics match after
normalizing checkout paths and stripping diagnostic timing lines; workload input
hashes match. The baseline is commit `8d7a15765`, before the separate inline-scope
byte scan. These measurements exclude C++ compilation and game runtime.
