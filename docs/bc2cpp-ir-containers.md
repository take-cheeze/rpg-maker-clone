# IR container shapes

The container shape analyses decide what an Array or Hash held in an instance
variable can contain:

- `RecordHash` (`tools/bc2cpp/record_hash.rb`, RECORD_HASH_PROOF, ADR 0285):
  per-key value classes of a Hash record with literal Symbol keys.
  `@slot.update({k: v, ...})` and `merge!` with no block count as one store per
  pair when the argument is a fresh Symbol-keyed literal (a `HASH` plus its
  `HASHADD` chunks, in a region nothing else enters, leaves or reads it in);
  `update`, `merge!` and `__merge` must keep core's definitions by the same owner
  rule as `delete`, which does not match native C definitions by owner.
  `BC2CPP_RECORD_HASH_UPDATE=0` treats the call as an escape again. Checked by
  `scripts/bc2cpp/record_hash_update_check.rb`.
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
| `codegen_record_hash.rb` (`record_index_mask`, RECORD_NILABLE_READ, via `ExactOracle#index_mask`) | a record key's Array/Hash/String classes, plus nil when the key can be absent | the exact-class flow, whose truthiness narrowing makes `@slot[:k] \|\| []` and `return unless x` exact and a plain read a NILABLE_RECEIVER; `BC2CPP_RECORD_NILABLE_READS=0` turns it off; checked by `scripts/bc2cpp/record_nilable_read_check.rb` |
| `rbs_record_types.rb` (`DeclScanner < RecordHash::Scanner`, `literal_keys`, `read_slots`, `Poison`) | declared record verification | codegen (verified names join the table) and the type check |
| `bc2cpp.rb` (`ArrayElementLayout.analyze` / `HashElementLayout.analyze`, `ELEM_HINT*` / `HASH_ELEM_HINT*` reports) | element tables | codegen (`CodeGen.new` element layouts) and report |
| `codegen_receiver_facts.rb` (`proven_element_class`, `proven_hash_element_class`; used by `codegen_loop_regions.rb` and `codegen_block_fallback.rb`) | element class of a block receiver | codegen (inlined loop element calls) |
| `codegen_declared_returns.rb` (`sealed_hash_read_failure`) | `@h[k]` is C or nil | codegen (unguarded `-> C?` declared return) |
| `scripts/bc2cpp/fixpoint_check.rb` | the two layout fixpoints | check only |

## On the IR

`tools/bc2cpp/bytecode_ir_containers.rb` gives the three analyses the facts they
used to read from `irep.instructions` (ADR 0502):

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
- `Program#constant_path(from, reg)` (`bytecode_ir_constant_path.rb`): the
  `Array` / `Hash` / `String` constant a register was loaded from, as a
  `BytecodeIR::ConstantPath`. It is a Program query because it is a pure
  reaching-definition walk over the instruction list; `Irep#constant_path`
  delegates to it.

What the analyses decide on top of these facts:

- The element scans join over every producer of a register (through handler
  edges): all must classify and agree, and an empty literal agrees with any
  class. A container literal counts only over a quiet span, so a local Array
  pushed to before it is stored is unknown, not vacuous.
- A mutation is attributed to the ivar of every `GETIV` producer of its
  receiver.
- RecordHash classifies a stored value with the type layer's literal classes.
- SEALED_HASH_IVAR reads its store literal, receiver and windows from the IR.

`trace_new_target` (`dispatch_targets.rb`), the receiver class trace the element
scans try first, walks on the IR: `walk_writers`, `walk_dominating_writers`,
`reaching_definitions` and `write_dominates?`. Its per-opcode arms dispatch on
the named sets in `tools/bc2cpp/bytecode_ir_receivers.rb` (`BytecodeIR::Receivers`)
and `BytecodeIR::Ops`, not on literal op names.

Still outside the IR, and why:

- `trace_new_target`'s arm bodies. They decide facts the instruction stream does
  not hold: a `.new` receiver is a class only when the closed world names it
  (`lexically_resolve_construct_target`, `construct_resolution_known?`,
  `UniqueClassNames`), a constant's container value comes from
  `container_constants`, and ivar, capture and return classes come from
  `ivar_classes`, `capture_hints`, `class_layout`, `registry` and the return
  proofs. These are program-level tables, not IR queries, so the walk keeps them
  as arguments.
- The RBS record checker's `DeclScanner` overrides (`rbs_record_types.rb`).

Record-hash alias scanning consumes the Integer registers exposed by the operand
layer directly. It does not rebuild those register arrays with `map(&:to_i)`.
HASHADD chunks also retain Integer key registers, matching the initial HASH
literal and avoiding numeric String construction during long-literal scans.
