# 0502. Container shape analyses read the bytecode IR

Date: 2026-10-19

## Status

Accepted

## Context

Three analyses decide what an Array or Hash held in an instance variable
contains: RECORD_HASH_PROOF (`record_hash.rb`, ADR 0285), the element layouts
(`element_layouts.rb`, ELEMENT_CLASS_SUPPORT / HASH_ELEMENT_SUPPORT) and
SEALED_HASH_IVAR (`codegen_sealed_containers.rb`, ADR 0456). Each indexed
`irep.instructions` itself: to find the literal that built a container, to read
the registers its elements came from, to classify a literal value, and to walk
straight-line windows. The element layouts also took the value of a register
from the textually nearest writer that dominates the read (JOIN_DOMINANCE,
ADR 0261), so a register written on two arms of a join was unknown even when
both arms agreed.

The shared bytecode IR already answers these questions: reaching definitions
over its CFG, predecessor sets with handler edges, and the literal table of its
type layer (ADR 0440).

## Decision

`tools/bc2cpp/bytecode_ir_containers.rb` adds the container facts to the IR:
`BytecodeIR.producers` (every definition reaching a read, with its writing
instruction), `Program#container_literal` (the Array or Hash literal an
instruction builds and its element, key and value registers, including the
two-register `ARRAY` form of ARRAY2), `BytecodeIR.literal_class` (the type
layer's literal classes), `Program#quiet_span?`, `Program#straight_line` and
`Program#adjacent_block_index`.

The three analyses read these facts and no longer index `irep.instructions`:

- The element scans join over every producer of a register, through handler
  edges. Every producer must classify and all must agree; an empty literal
  agrees with any class. A dataflow refusal answers nil. A container literal
  counts only when the span from it to the read is quiet
  (`Program#quiet_span?`: loads and jumps that stay inside the span), so a local
  Array mutated before it is stored is unknown rather than vacuous. Element
  hints are forced by the strict hint tier (ADR 0419), so the join must not
  admit more than the old walk admitted for that reason.
- A mutation is attributed to the ivar of every `GETIV` producer of its
  receiver, through handler edges.
- RecordHash classifies a stored value with the type layer's literal table, so
  a Range, Proc or `SYMBOL` literal is a known class instead of unknown.
- SEALED_HASH_IVAR reads its store literal, receiver and windows from the IR.

The move went through a stage switch (`BC2CPP_IR_CONTAINER_SHAPES`, removed
once the comparison was done) whose `compare` mode answered from the old walks
and logged every query the IR answered differently.

What stays outside the IR: `trace_new_target` (the receiver class trace the
element scans call first), `RecordHash::Scanner#strict_new_class`'s
`constant_path` (constant analysis is moving separately), and
`rbs_record_types.rb`'s DeclScanner overrides, which belong to the RBS record
checker.

## Consequences

On the engine (wio closed world) the comparison found no disagreement for
RecordHash, SEALED_HASH_IVAR or mutation attribution. The element scans
disagreed on eight queries before the quiet-span rule, each one the IR
answering where the old walk could not: a register set on both arms of
`x || []` or a two-Symbol conditional, the two-register ARRAY form the old scan
never decoded, and two empty literals behind a loop (the case the quiet-span
rule now refuses). None of them changed an element table entry, so the
generated C++ for the engine is byte-identical; a program whose ivar is only
reached through such a join gains the hint.

`scripts/bc2cpp/ir_container_shapes_check.rb` covers the facts on hand-built
instruction lists.
