# 0503. bc2cpp: return and receiver class analyses read BytecodeIR return sites

Date: 2026-10-19

## Status

Accepted

## Context

The return-class analyses in `tools/bc2cpp` each walk `irep.instructions` for the same few questions: which
instructions leave the frame, which `return`s nested blocks hold, whether a nested block can `break`, and which
writes supply the returned register. Each answer was written again per pass:

| Raw walk | File | What it answers |
| --- | --- | --- |
| `fixnum_return_sites_proven?`, `array_return_sites_proven?`, `class_return_sites_proven`, `fixnum_return_analyzable?`, `class_return_analyzable?` | `codegen_return_analysis.rb` | exit sites of a body |
| `subtree_has_nonlocal_exit?` | `codegen_return_analysis.rb` | a nested RETURN_BLK or BREAK |
| `return_value_sources` | `codegen_return_analysis.rb` | its own reaching-definitions worklist (JOIN_REACHING_DEFS' barriers) |
| `return_write_dominates?` | `codegen_return_analysis.rb` | its own copy of REGION_DOMINANCE |
| `own_upvar_written_regs`, `collect_own_upvar_writes` | `codegen_return_analysis.rb` | a copy of `BytecodeIR.own_upvar_written_regs` |
| `declared_return_failures`, `declared_block_returns`, `declared_subtree_breaks?` | `codegen_declared_returns.rb` | exit sites, nested returns, nested breaks |
| `return_class_def_mask`, `return_class_block_returns`, `return_class_context_def_mask`, `return_class_context_block_returns` | `codegen_return_classes.rb` | exit sites and nested returns, joined over the exact-class flow |
| `compute_return_classes`, `admit_checked_alias_names` | `codegen_return_classes.rb` | the bodies that call a tracked name |
| `compute_pool_self_class_refusal` | `codegen_return_classes.rb` | a rebinding send anywhere |
| `block_carrying_callers_of`, `module_function_copy_self_safe?` | `codegen_receiver_facts.rb` | block-carrying sends of a name; a nested body's ops |

The facts these walks produce feed codegen and reports:

* `fixnum_return_names` (FIXNUM_RETURN_PROOF): Fixnum operand proofs (`codegen_fixnum_proof.rb`), ClassLayout's
  input (`bc2cpp.rb`), and the type report (`type_facts.rb`, `param_trace.rb`).
* `array_return_names` (ARRAY_RETURN_PROOF): the loop recognizers (`codegen_loop_regions.rb`), the declared Array
  check (`codegen_declared_returns.rb`), ClassLayout's probe and the report.
* `class_return_names` (RETCLASS_SELF_CALL_SUPPORT): ClassLayout (`ivar_layout.rb`), `trace_new_target`'s
  `method_return_class` at every guarded send (`codegen_send.rb`) and the declared class check.
* The exact-class return table (`@rc_return`, `return_class_def_mask`): `return_class_send_mask`, so every
  `exact_flow_*` receiver fact in codegen; the reports read `return_class_def_mask` directly
  (`type_facts.rb`, `receiver_proof_report.rb`, `send_root_report.rb`).
* DECLARED_RETURN_CHECK (`declared_return_facts`, ADR 0455): the three fixpoints above are seeded with the checked
  declarations, and its diagnostics fail a build.
* `receiver_trace_origin`: only the text of a POLY diagnostic comment and two reports.

The IR already answers the hard part: `Program#reaching_definitions` and `Program#write_dominates?` (ADR 0476, ADR
0261), with the same audited op list, callee-frame clobbers and nested-block writes, and handler edges on request.

## Decision

`tools/bc2cpp/bytecode_ir_returns.rb` (RETURN_SITES, `docs/bc2cpp-ir-return-sites.md`) adds:

* `Program#exits`: every frame exit with its kind (`:value`, `:block_return`, `:nil`, `:self`, `:true`, `:false`,
  `:break`, `:stop`), and `exit?`.
* `BytecodeIR.nested_bodies`, `nested_exits` and `nested_exit?`, over `Irep#tree`.
* `Program#return_sources` / `BytecodeIR.return_sources`: `reaching_definitions` over handler edges with the body's
  own nested-block writes opaque. A LOADNIL, and the fall-through of a RAISEIF of the register, are nil sources; an
  entry value refuses.

Two refinements of the shared dataflow, both only ever turning a refusal into an answer that vm.c guarantees:

* `reaching_definitions(raiseif_nil: true)`: vm.c OP_RAISEIF falls through only when R(a) is nil, so on the normal
  edge the RAISEIF is the register's (nil) definition. Off by default; `return_sources` turns it on. Without it the
  walk of `x rescue y` crosses the handler's RESCUE and refuses.
* `write_dominates?` steps over a frame exit inside the region without counting its leading register as a write: a
  RETURN reads it, and nothing falls through from an exit to the use. This is a change for every caller.

The consumers move: the Fixnum, Array and class return proofs, DECLARED_RETURN_CHECK and the exact-class return
table walk `exits` and `nested_exits`; `return_value_sources` is `BytecodeIR.return_sources` and
`return_write_dominates?` is `BytecodeIR.write_dominates?`, so the private worklist, its region test, the
`own_upvar_written_regs` copy, `fixnum_proof_writes_reg?` and `FIXNUM_PROOF_REACHING_MAX_STATES` are deleted, and the
barrier shadow (ADR 0250) loses its two hooks on them. The bodies that call a tracked name come from one per-op index
instead of two whole-program scans; the pool-self, `module_function` and block-carrying-caller scans ask the IR by op.

Three linear walks stay. `straightline_return_reg?` finds the textually preceding writer because `trace_new_target`
and `proven_array_source`, which prove that writer, scan the same way (only its dominance moves to the IR).
`rescued_exception_receiver?` follows a handler's exception register to its EXCEPT, a handler entry the normal walk
refuses at. `receiver_trace_origin` labels where the linear receiver trace stopped, for a diagnostic. The exact-class
oracles (`ExactOracle#ivar_slots`) belong to the numeric-flow move and are left alone.

### Comparison on the engine (stage switch, removed)

`BC2CPP_IR_RETURN_SITES=compare` asked both answers over the type check's engine world. Before the two refinements,
393 return-source questions disagreed (all `x rescue y`: the IR refused at RESCUE where the old walk read the RAISEIF
as nil) and 20 dominance questions (an early `return ids` between `ids = []` and the read). After them the only
disagreements are four return sites where the old walk refused and the IR answers: two bodies past the old fixed cap
of 400 states, a dead predecessor after a RETURN_BLK, and a JMPUW outside every protected range.

## Consequences

* The generated C++ of the engine world is byte-identical to master's, and so are the RET, ARET, RETCLASS and
  DECLARED_RET listings. The type report changes in two return `reason` strings only (the IR names more sources).
* A return proof now refuses exactly where `reaching_definitions` does, so a future improvement of the shared walk
  reaches these proofs without a second copy to update.
* `scripts/bc2cpp/ir_return_sites_check.rb` covers the queries and both refinements on hand-built bytecode.
