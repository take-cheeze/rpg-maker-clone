# NIL_NARROWING and ESCAPE_ANALYSIS on the bytecode IR

`tools/bc2cpp/nil_narrowing.rb` (NIL_NARROWING, ADR 0456) and
`tools/bc2cpp/escape_analysis.rb` (ESCAPE_ANALYSIS, ADR 0316) are both standard
dataflow analyses. This page records which parts of them read the bytecode IR
(`tools/bc2cpp/bytecode_ir*.rb`) and which read the raw `irep.instructions`
list, and who consumes their answers.

## Consumers

| Consumer | Analysis | Feeds |
| --- | --- | --- |
| `tools/bc2cpp/rbs_param_check.rb:332` (`NilNarrowing.non_nil?`) | NIL_NARROWING | RBS_CHECKED_PARAMS: whether a declared class parameter is kept (codegen) and its TC diagnostics (report) |
| `tools/bc2cpp/rbs_param_check.rb:345` (`NilNarrowing.instance_of?`) | IS_A_GUARD | same |
| `scripts/bc2cpp/join_dominance_check.rb` | both | host check only |
| `tools/bc2cpp/codegen_escape.rb:29` (`block_proven_to_stay?`, called from `codegen_block_fallback.rb:364`) | ESCAPE_ANALYSIS | BLOCK_FALLBACK_PROVEN: whether a block's captured pointers may stay on the frame (codegen) |
| `tools/bc2cpp/rbs_record_types.rb:581` (`name_captures_arg?`) | ESCAPE_ANALYSIS | RBS_RECORD_TYPES' interprocedural Hash scan (codegen: the RECORD_HASH table) |
| `tools/bc2cpp/escape_report.rb` (`creation`, `captures?`) | ESCAPE_ANALYSIS | `BC2CPP_ESCAPE_REPORT` TSV (report only) |
| `tools/bc2cpp/bc2cpp.rb:344` (`EscapeAnalysis::World.new`) | ESCAPE_ANALYSIS | builds the world; its definition scan feeds every query above |

## Raw-instruction walks

NIL_NARROWING already iterated BytecodeIR's CFG (normal and handler
predecessors). Its raw walks were the operand reads of each edge's source
instruction and `copy_source`, a backward scan of up to 64 instructions for
the `MOVE r b` a tested register was copied by, checked with
`write_dominates?` and a linear scan for writes of `b`.

ESCAPE_ANALYSIS's frame flow already ran on BytecodeIR's successors and
handler edges. Its raw walks were the op scans: the world's definition scan
(`World#scan_definitions`, closure bodies), `creation`, the BLKPUSH sources of
a method's block, `closure_children`, `subtree_refs` and the address of a
closure reason.
