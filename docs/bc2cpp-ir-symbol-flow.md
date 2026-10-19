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
