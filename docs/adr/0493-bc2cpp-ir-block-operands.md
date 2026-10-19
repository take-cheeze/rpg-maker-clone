# 0493. Block and yield analyses read registers through the bytecode IR

Date: 2026-10-19

## Status

Proposed

## Context

Four bc2cpp analyses about blocks answer "what does this register hold here?"
by looking at the instruction textually before the read:

- `yield_reach.rb` (YIELD_REACH, ADR 0283) traces block operands, receivers
  and arguments with `Irep#source_writer`, a per-register writer list and a
  "no jump lands in between" test, and recognises a literal block only when
  the `BLOCK` is the instruction right before the send;
- `block_self_world.rb` (BLOCK_SELF_WORLD, ADR 0477) uses the same adjacency
  test for literal blocks at rebinder sites and `walk_dominating_writers` for
  constant receivers, and asks `BytecodeIR::Program#reaching_definitions`
  without the irep's nested `SETUPVAR` writes;
- `block_returns.rb` (BLOCK_RETURNS, ADR 0475) asks the same unqualified
  `Program` query;
- `codegen_block_param_call.rb` (BLOCK_PARAM_CALL, ADR 0274) already uses
  `BytecodeIR.reaching_definitions`.

`ir_yield_types.rb`, `ir_block_captures.rb` (ADR 0449) and
`codegen_captured_locals.rb` (ADR 0308) look like IR replacements of these, but
they answer other questions: the first two are reporting-only type feedback
(ADR 0449 forbids feeding optimizer dispatch from them), and the third types a
captured local for numeric flow. None of them duplicates a raw walk above, so
ADR 0449's reason for keeping them separate still holds and they stay as they
are.

Consumers of the four analyses:

| Fact | Consumer | Use |
| --- | --- | --- |
| `YieldReach#yield_free?` | `codegen_yield_free.rb:30` (`yield_free_block?`), `codegen_numeric_slow_zero.rb:73`, `codegen_core_compiled_cmp.rb:52` | codegen |
| `YieldReach#body_yield_free?` | `codegen_yield_free.rb:45` (`core_body_relaxable?`, read by `codegen_method.rb:828,848`, `codegen_block_core_direct.rb:187`, `codegen_core_exact_direct.rb:130`, `codegen_native_owner_map.rb:111`, `codegen_receiver_facts.rb:682`) | codegen |
| `YieldReach#fiber_unsafe` | `codegen_block_fallback.rb:292` (FIBER_REACHABILITY_UNSAFE) | codegen |
| `YieldReach#builds_enumerator?` | `codegen_method.rb:826` (FIBER_BODY_GUARD) | codegen |
| `YieldReach#stats` | `codegen_yield_free.rb:51` (`yield_free_report`, `bc2cpp.rb:2004`) | report |
| `BlockSelfWorld` `rebound` | `codegen_block_self.rb:47`, `closed_world.rb:227`, `codegen_numeric_ivars.rb:72` | codegen |
| `BlockSelfWorld` `holds?` | `codegen_block_self.rb:53,69` (entry self check, BLOCK_SELF) | codegen |
| `BlockSelfWorld` `why`, `sites` | `bc2cpp.rb:510` | report |
| `BlockReturns.ruby_body_why` | `codegen_block_returns.rb:82` (TC1010, block-return facts) | codegen and build gate |
| `block_param_call_code` / `_splat_code` | `codegen_send.rb:1749`, `codegen_keyword_send.rb:659` | codegen |

## Decision

Answer these register questions with BytecodeIR reaching definitions through
one small module, `tools/bc2cpp/ir_block_operands.rb` (IR_BLOCK_OPERANDS): the
block register of a send, the literal blocks every reaching definition of it
creates, the constant a receiver holds, and whether an instruction is
reachable. Its queries count nested blocks' `SETUPVAR` writes, cross handler
edges and use the origin walk's `RESCUE`/`EXCEPT`/`ENTER` model, so a slot
`ENTER` stores (the block parameter, R1) is defined by the `ENTER`.

Each consumer states what a refused query means. A question whose positive
answer enables an optimisation (a literal block, a constant receiver, a
non-Proc receiver) treats a refusal as "no". YIELD_REACH's escape scans (does
the method keep its block, does a generator leak its yielder) ask "may the
register hold it": one matching definition is enough, and a register a point
query refuses falls back to every value it can hold anywhere in the frame,
including nested blocks' `SETUPVAR` stores.

The flow-insensitive scans stay: the writers of a captured block parameter
(`classify_upvar`, `block_param_slot_pristine?`, `captured_block_param?`,
`upvar_names`), the nested-exit scan of BLOCK_RETURNS and the per-op
inventories of every analysis ask about the whole frame, because a closure can
read a captured local at any time, not at one instruction.

## Consequences

- Joins are no longer read as "the last writer": an escape through a
  conditional assignment (`b = c ? blk : nil; @x = b`) now marks the block
  captured, and a `SETUPVAR` from a nested block now refutes a computed-send
  name proof.
- A literal block reached through a local (`b = -> {}; o.instance_exec(&b)`)
  is a literal rebinder site: the block is rebound instead of failing the world
  fact.
- `x[i]` checks the receiver, not the index register.
- The handler model is path-insensitive: a block pushed for a `yield` inside
  `begin ... ensure` reaches the method's return on the raising path, so
  `IO.open`, `IO.popen`, `IO.pipe` and `StringIO.open` count as keeping their
  block. That only makes the proof more conservative.
- `BC2CPP_IR_BLOCK_FLOW` selected the IR answers while both existed; the old
  walks are removed and the variable is gone.
