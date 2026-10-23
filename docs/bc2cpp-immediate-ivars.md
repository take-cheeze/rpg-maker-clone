# Immediate ivars: the first slice of in-frame object placement

**Status: report only. Stack or in-frame placement of objects is NOT enabled.** The escape analysis
(`tools/bc2cpp/escape_analysis.rb`) proves some `new` objects confined to the frame that made them. This slice
records one more fact about each confined object, whether every ivar it stores is an immediate value, and adds the
tripwire and differential harness that any later placement must pass. Generated code does not change.

## The fact

`tools/bc2cpp/escape_immediate_ivars.rb` reopens `EscapeAnalysis::Analyzer` with `object_ivar_stores(irep, index,
klass)`. For a `new` site the analysis proves confined, it returns one of:

| Verdict | Meaning |
| --- | --- |
| `immediate` (n stores) | every `SETIV` that can reach the object stores a provably immediate value |
| `not_immediate` (why) | a store may hold a heap reference, or the set of stores cannot be enumerated |

An immediate value is one `nil`, `true`, `false`, a symbol, or an integer loaded by `LOADNIL`, `LOADTRUE`,
`LOADFALSE`, `LOADSYM`, `LOADI*` (`LOADL`, which reads the constant pool, is not immediate: a float or a bignum
there is a heap object in this build). A register is immediate when every write to it in its frame is such a load
or a `MOVE` from another such register, and it is not a formal parameter or the block slot. Anything else is not
immediate, so an unknown value counts as a heap reference.

The frames that can store into the object are:

- the creating frame, where the object is the `new` register (its own `self` is not the object);
- `initialize` (`self` is the object);
- every method reached by a send whose receiver is the object, by name over the whole world (`self` is the object).

A forward may-alias flow tracks the registers holding the object in each frame, with kills on overwrite and handler
edges, as the escape analysis does. An attribute writer reached by a send on the object is a store of its argument.
Any use the flow does not model makes the store set unenumerated, which is `not_immediate`. The cases that do so:

- the object is an argument, a block, a return value, or the operand of an array, hash, range, or class window;
- a closure (`BLOCK`, `LAMBDA`) in a scanned frame, since it may run with the object (see Limits);
- `super`, `RETSELF` of self, or an unmodelled op that touches a register holding the object;
- a send on the object whose callee set is unknown, empty, or native (`inspect`, `instance_variable_set`, ...).

The escape verdict still decides confinement. Only a confined site gets an answer here.

## Report

`BC2CPP_ESCAPE_REPORT=<tsv>` writes one `ivars` row per confined `new` site, next to its `site` row:

```
ivars  <irep>:<index>  <Class#method>  engine|core  SEND0  object  confined  immediate|not_immediate  <detail>  <Class>  -
```

`scripts/bc2cpp/escape_report.rb` prints the counts (every irep and shipped methods) and the top reasons an object is
not immediate. Labels in the reasons are irep labels, so read them with the `ivars` row's owner column.

## Tripwire and harness for any later placement

These are the gates a stack or in-frame placement must pass before it is enabled. The harness that runs them is
[`bc2cpp-placement-harness.md`](bc2cpp-placement-harness.md) (`scripts/bc2cpp/placement_harness_check.rb`): gates 1 and 2
run on the heap build, gate 3 as a smoke run, and the differential (gate 4) is a stub until placement exists. No placement is wired to them.

1. **Frame-exit tripwire.** When a frame that placed an object returns, walk the live heap (the VM's object list, the
   roots and the registers of live frames) and fail on any pointer into the frame's stack range. An immediate-only
   object holds no heap reference to anything the frame owns, so a pointer into its stack range is a confinement bug,
   not a value to fix up.
2. **GC stress around the frame exit.** Run the placed frame under `mrb_full_gc` (or the GC-every-allocation mode) on
   entry and exit, so a stale pointer to a freed or moved placed object is found at the point it becomes stale, not
   later in the game.
3. **ASan with `detect_stack_use_after_return`.** Build the placement under AddressSanitizer with
   `ASAN_OPTIONS=detect_stack_use_after_return=1`, so any read or write through a pointer kept past the frame is a
   report at the access, not a silent corruption.
4. **Heap-versus-stack differential.** Run each fixture twice: with the object on the GC heap (the current output) and
   with it placed. The observable result (return value, ivars read back, output) must be identical, and the GC object
   counts must differ only by the placed objects.

The fixture set for these gates is the `ivars` rows of `scripts/bc2cpp/immediate_ivars_check.rb` (below), extended
with runtime tests in `scripts/bc2cpp/placement_harness_check.rb`.

## Check

`scripts/bc2cpp/immediate_ivars_check.rb` (run in the bc2cpp checks job, `MRBC` set) generates small fixtures and
asserts the classification:

- an object with integer, nil and true ivars, one set by a send on it, is `immediate`; an attribute writer store is too;
- a string, an array, or a stored parameter is `not_immediate`; so is a closure in the creating frame;
- an object kept by its own initialize, or stored in a global, is not confined and has no `ivars` row;
- the generated C++ is byte-identical with and without `BC2CPP_ESCAPE_REPORT` (the report is read-only).

## Measured on the repo's escape fixtures

`scripts/bc2cpp/escape_fixture.rb` has two fixtures. The unit fixture has no confined `new` site. The program
fixture has one, and its block captures the object's creating frame, so it is `not_immediate` (closure). These are
the only confined object sites the existing fixtures contain. A closed-world engine census was not run for this change
(the closed build needs the sibling gem checkout layout; see the PR); the first measurement belongs in the PR that
enables a consumer.

## Limits

- Closures in a scanned frame are unenumerated, even when they do not touch the object. An upvar walk (the register a
  closure reads through `GETUPVAR`) would let `each { }` in `initialize` through.
- Store values are flow-insensitive: a register written once by a load and once by a `MOVE` from a parameter is not
  immediate. Rejecting more is the conservative side, and it costs precision only where a register is reused.
- A parameter is not immediate even when every caller passes an integer. Interprocedural value flow is not modelled.
- `super` and a `BasicObject#initialize` that is not the plain `mrb_do_nothing` are unenumerated; only the latter is
  taken as storing nothing.
- The ivars row is per `new` site with the constructed class. A site whose class is unknown is not confined, so it has
  no row.
