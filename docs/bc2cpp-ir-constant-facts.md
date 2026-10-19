# bc2cpp constant facts from the bytecode IR

ADR 0493 has the decision. This page is the how-to.

`BytecodeIR::ConstantFacts` (`tools/bc2cpp/bytecode_ir_constants.rb`) derives, for every constant
binding, its class set, exact integer value and Fixnum interval. It uses the IR's reaching definitions
(`BytecodeIR::Program#reaching_definitions`), so it follows MOVEs and joins without a separate walk.

- `paths`: one fact per full lexical path (`RPG2k::Scene::Map::TILE`). This is the binding's own value.
- `groups`: one fact per bare name. A read (GETCONST / GETMCNST) resolves by bare name, so this is what a
  read sees. A bare name with a CLASS/MODULE of that name, or a native or foreign Ruby definition, has
  no fact.

A fact field is unknown (`nil`) when any writer is not modelled. Values and intervals are bounded by the
Fixnum margin, so an out-of-margin value is never folded.

## Reading the report

A bc2cpp run prints, after the proof sections:

```
== BYTECODE_CONSTANT_FACTS (report-only): 1034 paths, 913 names ==
  IR_CONST RPG2k::Scene::Map::SLIDE_UNITS classes=Integer value=64 interval=64..64
  IR_GROUP TILE classes=Integer value=16 interval=16..16
```

`classes=?` means unknown, `value=-` no exact value, `interval=-` no interval.

To compare the IR facts with the proofs of the same run:

```
ruby scripts/bc2cpp/ir_constant_facts_compare.rb BUILD_LOG
```

It lists each disagreement by category (`admitted-only-in-proof`, `admitted-only-in-ir`, `value`,
`interval`, `class`). A type-check run gives the same sections in `bc2cpp.stderr` (`--keep DIR`).

## Checks

`MRBC=path/to/host/mrbc ruby scripts/bc2cpp/bytecode_ir_constants_check.rb` compiles fixtures and checks
values, intervals, classes, the operator gate, poison and the Fixnum margin. It runs in the `bc2cpp-build`
job next to the integer arithmetic check.
