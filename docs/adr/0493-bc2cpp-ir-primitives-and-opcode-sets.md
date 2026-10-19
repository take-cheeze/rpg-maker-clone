# 0493. Irep scans delegate to BytecodeIR::Program; one home for opcode sets

Date: 2026-10-19

## Status

Accepted

## Context

Two copies of the same backward-walk primitives existed. `Irep#last_writer_index`,
`#source_writer`, `#each_with_op`, `#index_of_addr` and `IrepScans#walk_writers` /
`#preceding_run` (about 45 calling files) kept their own per-irep index lists,
while `BytecodeIR::Program#copy_root`, `#each_with_op` and a private linear
`#last_writer_index` answered the same questions over the IR. Passes moving onto
the IR (ADR 0467, 0476) would otherwise keep two implementations whose answers
can drift apart.

Opcode-meaning tables were copied the same way: about a dozen `SEND_OPS` /
`CALL_OPS` sets, `READ_ONLY_OPCODE_SKIP`, NumericFlow's call and no-write sets,
each spelling the same vm.c facts by hand.

## Decision

`BytecodeIR::Program` (bytecode_ir_regions.rb) owns the linear primitives:
the indexed `last_writer_index`, `walk_writers` (with `BytecodeIR::Follow` /
`KEEP`), `copy_root` built on it, the indexed `each_with_op` and
`run_of_op_ending`. The Irep methods keep their names, signatures and results
and call `BytecodeIR.for(irep)`; `IrepScans::Follow` / `KEEP` are the IR's
objects, so existing block protocols are unchanged.

`tools/bc2cpp/bytecode_ir_ops.rb` (`BytecodeIR::Ops`) is the home of
opcode-meaning sets: `SEND`, `CALL`, `CALLEE_FRAME`, `READS_LEAD`,
`LEAD_READ_ONLY`, `FRAME_EXIT`, `PURE_LOAD`, `EXT`. New code names these; an
analysis-specific set is built from them (`Ops::LEAD_READ_ONLY | ['BLOCK']`).
The existing copies in other passes move over file by file.

These remain linear-order queries (the textually preceding writer). Dominance
and join-aware answers stay `walk_dominating_writers` (ADR 0261) and
`reaching_definitions` (ADR 0476); this decision does not change which a pass uses.

## Consequences

Every Irep that a scan touches now builds its `Program` (CFG edges and blocks,
linear in the instruction count) instead of two group-by tables; the Program is
cached on the irep and most ireps already built one. A differential run over the
lcf, rgss and rpg2k ireps found no answer that differs from the old walks.

Follow-up: the remaining table copies (alias_sites, call_site_index,
closed_world, define_method_sites, escape_analysis, provable_error_report,
rbs_record_types, receiver_proof_report, yield_reach, type_facts, record_hash,
numeric_flow, ivar_layout, bytecode_ir_dataflow, bytecode_ir_types, ...) point
at `BytecodeIR::Ops` in the batches that own those files.
