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

## IR implementation and comparison

During the migration `BC2CPP_IR_NIL_ESCAPE=1` ran both analyses on the IR and `=compare` kept the
legacy answers, logging each disagreement (`NIL_NARROWING_IR_DIFF`,
`ESCAPE_IR_DIFF`). Both are gone now that the IR is the only implementation.

NIL_NARROWING's IR flow (`NilNarrowing::Flow`) replaces the `copy_source`
back-walk with **available copies** carried in the must-state: `MOVE d s`
adds the pair `[:copy, d, s]` (and `d` with every register `s` is a copy of),
and a write of either register drops it. A test or a call that narrows `r`
then narrows every register paired with `r`. Ops are read from
`Program#decoded` and writes from `Program#may_write_at?`.

Over the 4249 ireps (125818 instructions) of the engine and mruby core image,
with a stand-in nil-answer table and a guard naming one class for every
`is_a?`, the IR flow proves **every** fact the legacy walk proves (0
legacy-only facts) and 2014 more, at 1923 instructions. The extra facts are
copies the one-hop, 64-instruction back-walk could not see: a sibling copy
(`stored = v; x = v; x.is_a?(K)` proves `stored`), a chain (`block = blk;
b = block; return unless b` proves the block slot itself), and copies that
reach a test through a join.

ESCAPE_ANALYSIS's op scans over the IR (`EscapeAnalysis.op_sites`, on
`Program#each_with_op`) return the same instructions, in the same order, as
the `irep.instructions` scans at all 31649 sites of the 4249 ireps: 0
disagreements. Its verdicts are therefore unchanged.

## What stays outside the IR

* NIL_NARROWING reads the operands it needs (a MOVE's source, a SEND's
  name) from the IR instruction's `source`: `Program#decoded` carries only
  the op, branch kind, leading register and target.
* ESCAPE_ANALYSIS's frame flow was already a may-alias flow over the IR's
  successors and handler edges; its per-op transfer (`Analyzer#step`) still
  decodes each operand from `source`, since the IR has no operand model.
  Reaching definitions answer a backward question for one register, which
  the forward flow of a value through many registers does not need.
* The closure-tree walk (`closure_children`, `subtree_refs`) follows the
  irep tree (`reps`) the IR does not model; only its op scans moved.
