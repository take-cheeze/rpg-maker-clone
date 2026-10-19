# IR container shapes

The container shape analyses decide what an Array or Hash held in an instance
variable can contain:

- `RecordHash` (`tools/bc2cpp/record_hash.rb`, RECORD_HASH_PROOF, ADR 0285):
  per-key value classes of a Hash record with literal Symbol keys.
- `ArrayElementLayout` / `HashElementLayout` (`tools/bc2cpp/element_layouts.rb`,
  ELEMENT_CLASS_SUPPORT / HASH_ELEMENT_SUPPORT): the one class every element
  of an Array ivar, or every value of a Hash ivar, has.
- SEALED_HASH_IVAR (`tools/bc2cpp/codegen_sealed_containers.rb`, ADR 0456):
  `@h[k]` is exactly C or nil for a Hash that never leaves its ivar.

## Consumers

| Consumer | Reads | Feeds |
| --- | --- | --- |
| `bc2cpp.rb` (`RecordHash.analyze`, `RECORD_HASH` report) | slots, refusals | report; `RecordHash.table` for the consumers below |
| `class_layout.rb` (`RecordHash.array_read?`) | `@ui[:key]` is a non-nil Array | codegen (ivar class `Array`) |
| `codegen_record_hash.rb` (`record_hash_exact_class`, used by `codegen_send.rb`) | exact class of a record key | codegen (unguarded exact receiver) |
| `rbs_record_types.rb` (`DeclScanner < RecordHash::Scanner`, `literal_keys`, `read_slots`, `Poison`) | declared record verification | codegen (verified names join the table) and the type check |
| `bc2cpp.rb` (`ArrayElementLayout.analyze` / `HashElementLayout.analyze`, `ELEM_HINT*` / `HASH_ELEM_HINT*` reports) | element tables | codegen (`CodeGen.new` element layouts) and report |
| `codegen_receiver_facts.rb` (`proven_element_class`, `proven_hash_element_class`; used by `codegen_loop_regions.rb` and `codegen_block_fallback.rb`) | element class of a block receiver | codegen (inlined loop element calls) |
| `codegen_declared_returns.rb` (`sealed_hash_read_failure`) | `@h[k]` is C or nil | codegen (unguarded `-> C?` declared return) |
| `scripts/bc2cpp/fixpoint_check.rb` | the two layout fixpoints | check only |

## On the IR

`tools/bc2cpp/bytecode_ir_containers.rb` gives the three analyses the facts they
used to read from `irep.instructions` (ADR 0493):

- `BytecodeIR.producers(irep, index, reg)`: every value that can reach a
  register read, each with its writing instruction, from the shared reaching
  definitions. Nil when the dataflow refuses.
- `Program#container_literal(index)`: the Array or Hash literal an instruction
  builds and the registers its elements, keys and values come from (`ARRAY`,
  the two-register `ARRAY` form of `ARRAY2`, `HASH`).
- `BytecodeIR.literal_class(irep, index)`: the value class a literal producer
  leaves, from the IR type layer's literal table (`Types::LITERAL_TYPES`, the
  pool types, `LOADI*`).
- `Program#quiet_span?`: nothing between a literal and its read can mutate
  it (only loads and jumps inside the span).
- `Program#straight_line`, `#adjacent_block_index`, `#each_source`,
  `#each_with_op`: the instruction-order questions, answered from the IR's
  predecessor sets.

`BC2CPP_IR_CONTAINER_SHAPES=1` answers from these facts; `compare` answers from
the legacy walks and prints `IR_CONTAINER_DIFF kind [where]: legacy=... ir=...`
for every query the two answer differently.
