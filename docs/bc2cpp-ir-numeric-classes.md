# bc2cpp: numeric class facts on the bytecode IR

NumericFlow (`tools/bc2cpp/numeric_flow.rb`, ADR 0276) is the forward class-mask
flow (`INT FLT ARR HSH STR NIL OTHER RNG EXC`, the closed-world class bits and
the LCF object kinds) that the unguarded numeric arms and every return-class
result read. ADR 0500 makes it read its instruction facts from the bytecode IR
(`tools/bc2cpp/bytecode_ir_numeric.rb`) instead of the raw `irep.instructions`.

## Consumers of the flow

Every run of the flow, and whether it feeds the generated code:

| Call site | What it computes | Feeds codegen |
| --- | --- | --- |
| `codegen_numeric_proof.rb` `numeric_states_for` | the numeric proof (`numeric_raw_mask`, `numeric_operand_mask`) behind the unguarded arithmetic and compare arms, native int arguments, numeric ivars/consts/args/returns, tuple returns, frozen tables, LCF rows, step loops | yes |
| `codegen_numeric_returns.rb` `numeric_return_def_mask`, `numeric_block_return_mask` | a method's numeric return mask from those states | yes |
| `codegen_return_classes.rb` `return_class_states`, `return_class_scoped_states`, `return_class_def_mask`, `return_class_block_returns` | the return-class pools (ADR 0289) | yes |
| `codegen_return_classes.rb` `return_class_context_mask`, `return_class_context_block_returns` | contextual return classes of one call site | yes |
| `ir_context_results.rb` `result` | IR contextual results (ADR 0447) | yes |
| `codegen_block_returns.rb` `block_return_class_result` | a block's return classes | yes |
| `codegen_core_ruby_results.rb` | the classes a core mrblib method returns | yes |
| `element_site_report.rb`, `provable_error_report.rb` | reports reading `numeric_raw_mask` | report only |

## What the IR supplies

- `Program#decoded` and `Program#operands`: the flow's Step table (op, branch,
  target, leading and second register, ivar).
- `Program#successor_lists`, `#raise_targets`, `#rescue_only_targets`: the
  edges (ADR 0467).
- `Program#exits` with `NumericClasses.exit_mask`, `.returned_mask` and
  `.block_return_mask`: the return folds every consumer above used to write as
  its own scan.
- `NumericClasses.element_literal_mask`: the literal-element proof (ADR 0354)
  on reaching definitions and the type layer's literal classes.

## What stays outside the IR

- The flow is still a forward abstract interpretation, not a reaching-definitions
  query: truthiness and class-test narrowing, ivar slots and handler states are
  path facts the per-query IR walk does not carry.
- The `op_native?` / `nil_raises?` gates and every other oracle question
  (`send_mask`, `pool_mask`, `const_mask`, ...) are answered by the consumer's
  oracle, which reads the operands of the instruction it is asked about.
