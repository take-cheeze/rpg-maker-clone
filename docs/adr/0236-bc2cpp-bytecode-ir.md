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
this view; generated output and proof behavior are unchanged.

## Consequences

Future analyses can share control-flow structure rather than each building a
partial CFG. The initial layer does not yet model register definitions or
perform data-flow analysis; those should be added with explicit opcode transfer
semantics and conservative refusal for instructions not modeled. This keeps
the IR useful without treating incomplete opcode knowledge as a proof.
