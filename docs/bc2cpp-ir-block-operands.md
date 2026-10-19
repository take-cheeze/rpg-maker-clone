# Block operands through the bytecode IR

YIELD_REACH (`tools/bc2cpp/yield_reach.rb`), BLOCK_SELF_WORLD
(`tools/bc2cpp/block_self_world.rb`) and BLOCK_RETURNS
(`tools/bc2cpp/block_returns.rb`) ask what a register holds at an instruction:
the block a send is given, the constant a receiver was loaded from, whether a
method keeps the block it received. They answer through
`tools/bc2cpp/ir_block_operands.rb`, which asks `BytecodeIR.reaching_definitions`
with nested blocks' `SETUPVAR` writes, handler edges and the origin walk's
`RESCUE`/`EXCEPT`/`ENTER` model.

- A send's literal blocks are the `BLOCK`/`LAMBDA` instructions every
  reaching definition of its block register comes from, wherever they are:
  `b = -> { }; o.instance_exec(&b)` is a literal rebinder site.
- A constant receiver (`Fiber`, `Enumerator`, a `Class.new` factory) is one
  constant every reaching definition loads.
- YIELD_REACH's escape questions (does a method keep its block, does a
  generator leak its yielder) count any matching definition, and fall back to
  every value a register can hold in the frame when a point query refuses.
- `x[i]` may run a Proc unless every definition of the receiver is a literal
  non-Proc value.

A refused query never proves anything: a literal block, a constant or a
non-Proc receiver is then unknown, and a kept block is assumed kept.

The flow-insensitive scans stay as they were: who writes a captured block
parameter, nested `return`/`break`/`yield` in BLOCK_RETURNS, and the op
inventories.

```sh
MRBC=/path/to/mrbc ruby scripts/bc2cpp/ir_block_operands_check.rb
```

See [ADR 0504](adr/0504-bc2cpp-ir-block-operands.md).
