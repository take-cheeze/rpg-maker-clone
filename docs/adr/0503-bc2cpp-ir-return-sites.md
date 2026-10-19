# 0503. bc2cpp: return and receiver class analyses read BytecodeIR return sites

Date: 2026-10-19

## Status

Proposed

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

To be filled in when the consumers move.

## Consequences

To be filled in when the consumers move.
