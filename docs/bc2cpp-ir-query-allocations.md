# Bytecode IR and decoder allocations

`BytecodeIR::Program` (the per-irep CFG and its queries) and
`InsnDecoder::Decoder` (RITE bytes to `Insn`) run once per irep or once per
query, many thousands of times in a sealed compile. An object-mode profile of
the sealed Optcarrot compile (`scripts/bc2cpp/compiler_profile.rb --mode object
--optcarrot`, see [compiler profiling](bc2cpp-compiler-data-profile.md)) put
about 6% of allocation samples directly in these frames. Most of those objects
were per-call scaffolding: splat and keyword Hashes, cache-key Arrays, copies
and intermediate lists.

## What changed

Instruction-index queries (`bytecode_ir_regions.rb`, `irep.rb`):

- `indices_with_op` answers a one-op query with `indices_by_op`'s own frozen
  list. That is the most common query, and it used to build `uniq`,
  `flat_map` and a `fetch(op, [])` default on every cache miss. A multi-op
  query still caches its merged list, and returns the single list unchanged
  when only one of its ops occurs. Missing ops share one frozen
  `BytecodeIR::EMPTY_INDICES`.
- `indices_by_op` and `lead_indices` fill their lists in one pass instead of
  `group_by` followed by `transform_values`/`map`.
- `Irep#each_with_op(*ops)` passes its op Array to `Program#each_with_op_in`
  instead of splatting it into a second Array.

Program construction (`bytecode_ir.rb`):

- `Instruction`, `BranchEdge` and `BasicBlock` are built positionally. They no
  longer set `keyword_init: true`, so keyword construction still works but a
  builder does not need a keyword Hash per instance.
- `@address_to_index` is filled while the instructions are built, without one
  pair Array per instruction from `to_h`. The placeholder successor list and
  instructions with no successors share `EMPTY_INDICES`, and a list with one
  target skips `uniq`.
- `build_blocks` sorts its leaders in place and fills an owner Array without
  the `[first, last]` range pairs or the per-block `Range`.

Dataflow (`bytecode_ir_dataflow.rb`):

- `BytecodeIR.reaching_definitions(irep, index, reg, ...)` lists
  `Program#reaching_definitions`' keywords and defaults explicitly instead of
  taking `**options`, so a call no longer allocates two Hashes. `opaque_regs:`
  still defaults to `own_upvar_written_regs(irep)` and is still overridable.
- On a cache miss, `Program#reaching_definitions` freezes the freshly computed
  definitions in place instead of copying each one into the cache.
- `compute_reaching_definitions` sorts its result with a comparison block
  instead of a `[index, reg]` key Array per definition. `(index, reg)` is
  unique in the set, so the order is the same. Its `seen` table and work stack
  are reused between walks (with a busy flag, so a nested walk would get its
  own).
- `write_dominates?` uses an Integer key, encoded like `reaching_query_key`,
  instead of a 4-element Array. An opaque key that cannot get an ID below the
  cache cap falls back to the Array key.
- `origin_effect` takes the instruction's index when the caller has it, so the
  reaching walk and `compute_write_dominates?` read the per-instruction
  `EffectEntry` table instead of building a fresh entry for every visit.

Decoder (`insn_decoder.rb`, `irep.rb`):

- Register, pointer-register and integer operands and the fixed literal
  operands (`nil`, `true`, `false`, `-1`, `0`..`7`) are frozen and shared:
  one `Operand` per value for the whole process. Nothing mutates an
  `Operand` after it is built.
- `sym` memoizes `SymbolDump.call` per symbol name. The dump depends only on
  the name's bytes, and the result was deduplicated with `-` anyway.
- `Insn.decoded` builds a decoded instruction without the two keyword Hashes
  `Insn#initialize` passes on.
- `operand_sizes` looks up a nested `ext -> format` table without a
  `[format, ext]` key, and `packed_int` reads with a plain `while` loop and
  returns the value alone, without a `[value, offset]` pair or the throw object
  that `break` out of a `loop` block allocates.

## Evidence

Generated C++ and the compiler log are identical after normalising the
per-run temporary directory (it appears in path comments and in one hex-encoded
pool string).

Comparison: one warm-up run, then three alternating `--mode none` runs of
master and this change on the sealed Optcarrot workload (Ruby 4.0.5 +YJIT):

| Run | master objects | new objects | master s | new s |
| --- | ---: | ---: | ---: | ---: |
| 1 | 10,839,360 | 10,085,190 | 11.35 | 10.89 |
| 2 | 10,839,334 | 10,085,138 | 9.96 | 9.02 |
| 3 | 10,839,348 | 10,085,194 | 9.88 | 9.28 |

The change allocates about 754,000 fewer objects (-7.0%). Elapsed time was
lower in all three pairs, but other jobs were running on the machine, so this
page makes no speed claim.

Checks: the `ir_*`, `numeric_*`, `typed_*`, `bytecode_ir_*`, `irep_*` and
`name_strings` checks pass, along with every other
`scripts/bc2cpp/*_check.rb` that references the touched methods (60 scripts
in all). Five fail for reasons outside this change.
`class_object_args_check` and `const_bitor_io_check` fail the same way on
master. The three `class_body_*` g++ steps fail because this checkout has no
generated `mruby/presym/id.h`.
