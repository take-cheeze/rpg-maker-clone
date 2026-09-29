# 0236. Introduce a bytecode IR for bc2cpp analysis

Date: 2026-09-28

## Status

Accepted

## Context

bc2cpp analyses repeatedly inspect mrbc disassembly directly. Each pass has to
interpret instruction positions and, where needed, reconstruct control flow.
That makes proofs such as resolving `Class#new` harder to compose and review.

## Decision

Add a conservative `BytecodeIR::Program` view over each IREP. It assigns stable
instruction indices, resolves branch targets to instruction indices, and
groups instructions into basic blocks with normal-flow predecessor and
successor edges. Exception-handler edges are not represented. The source
disassembly remains attached to each IR instruction and remains the authority
for opcode semantics. Existing class tracing consumes instructions through
this view. For a stable class constant whose `Class#new` and `Class#allocate`
lookup is proven standard, bc2cpp may lower a blockless positional `.new` to
mruby's `mrb_obj_new`. That API performs the same allocation and keeps
`#initialize` dynamically dispatched, including native initializers. A
class-identity guard retains ordinary dispatch for Modules, non-class values,
and a receiver register that differs from the traced constant.
Constructor proof also rejects `Class` mixins that could replace lookup for
every class object's `new` or `allocate` method. When the class has one clean,
compiled positional `#initialize` and is emitted in the same translation unit,
bc2cpp can call that implementation directly after matching allocation. The
initializer's return value is discarded, as `Class#new` requires.

## Consequences

Future analyses can share control-flow structure rather than each building a
partial CFG. The layer does not yet model register definitions or perform
data-flow analysis; those should be added with explicit opcode transfer
semantics and conservative refusal for instructions not modeled. Constructor
lowering still requires a class fact already established by the existing trace.
