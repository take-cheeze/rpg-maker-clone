# NIL_NARROWING and ESCAPE_ANALYSIS on the bytecode IR

`tools/bc2cpp/nil_narrowing.rb` (NIL_NARROWING, ADR 0456) and
`tools/bc2cpp/escape_analysis.rb` (ESCAPE_ANALYSIS) are both standard
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
| `tools/bc2cpp/codegen_stack_tuples.rb` (`stack_tuple_site`, `creation`'s `tracked` set) | ESCAPE_ANALYSIS, reaching definitions | STACK_TUPLES (ADR 0545): a non-escaping literal Array of immediates is a C++ buffer; `BC2CPP_STACK_TUPLES=0` disables it |
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

* NIL_NARROWING reads its operands through `BytecodeIR::OperandModel`
  (`tools/bc2cpp/bytecode_ir_operands.rb`): a MOVE's two registers, a SEND's
  receiver and name, a conditional branch's tested register. The model builds
  them from the instruction's `source`, because `Program#decoded` carries only
  the op, branch kind, leading register and target. The op itself still comes
  from `source.op`. Operands of ops that neither pass reads are not modelled.
* ESCAPE_ANALYSIS's frame flow was already a may-alias flow over the IR's
  successors and handler edges. Its per-op transfer (`Analyzer#step` and the
  send helpers it calls) reads its operands through `BytecodeIR::OperandModel`:
  the leading and every register operand, the first register operand, a MOVE's
  source, an APOST's post count, a send's receiver, name and argument counts,
  an integer, a `src_and_literal` pair and a BLKPUSH's paren value. Each is the
  `Insn` accessor's value, read from `source`. The op name and the instruction
  address still come from `source` (`op`, `addr`), since they are not operands.
  Reaching definitions answer a backward question for one register, which
  the forward flow of a value through many registers does not need.
* The closure-tree walk (`closure_children`, `subtree_refs`) goes through
  `BytecodeIR::Tree`, which takes the ireps table explicitly because copied
  subtrees are registered there and not in `Irep#tree`.

## Native method facts

A `SEND` hands its arguments and receiver to every definition of the name. A
native (C) definition has no bytecode body, so its effect comes from two
audited tables in `escape_analysis.rb`:

* `NATIVE_RECEIVER_OK` (receiver kept or not, `:fresh` / `:self`). `freeze` is
  `:self`: `mrb_obj_freeze` returns its receiver, and every registration is listed in
  `NATIVE_MANIFEST`.
* `NATIVE_ARG_OK` (argument positions the natives keep none of, with the
  registering files and the Ruby methods the natives call with the argument).
  `==`, `equal?`, `eql?`, `is_a?`, `kind_of?`, `instance_of?`, `key?`,
  `has_key?` and `section` are audited. A name whose natives call `to_str`,
  `coerce` or `<=>` on the argument stays unaudited; `+` (Rational's default
  branch calls `arg + self`, and the result is returned) and `<<` (`Array#<<`
  stores its argument) do too.

`NATIVE_ARG_OK` applies only when every `NATIVE_SRCS` registration of the name
sits in an audited file, so a new native refuses the name. A callback on the
argument resolves on the argument's exact class when the analysis knows it
(`value_class`), otherwise on every definition of the name. The `<native>`
definitions are not Ruby callees, so they do not veto an audited name.

## Validation

* `scripts/bc2cpp/join_dominance_check.rb` (now with copy-chain, sibling,
  join and negative cases), `declared_return_guard_check.rb` and
  `generic_block_return_check.rb` pass.
* `MRBC=… ruby scripts/bc2cpp/type_check.rb --no-sends -q` exits 0.
* `scripts/bc2cpp/closed_build.bash` generates and compiles the four
  `*-compiled` gems.
