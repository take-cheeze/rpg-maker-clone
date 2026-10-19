# Bytecode IR return sites

The return and receiver class analyses ask the bytecode IR how a body leaves its frame and where the values it
returns come from (`tools/bc2cpp/bytecode_ir_returns.rb`, [ADR 0503](adr/0503-bc2cpp-ir-return-sites.md)).

```ruby
program = BytecodeIR.for(irep)
program.exits                       # [Exit(index, source, kind)], kind :value :block_return :nil :self :true :false :break :stop
program.exit?(:value)               # any `RETURN R(a)`
BytecodeIR.nested_bodies(irep)      # every block and lambda below irep, depth first (Irep#tree)
BytecodeIR.nested_exits(irep, :block_return)  # [[child, Exit]]: the `return`s inside blocks
BytecodeIR.nested_exit?(irep, :break)
BytecodeIR.return_sources(irep, index, reg)   # [[writer, reg] | :nil] or nil
```

`return_sources` is `reaching_definitions` over handler edges with the body's own nested-block writes opaque. A
`LOADNIL`, and the fall-through of a `RAISEIF` of the register (vm.c raises unless it is nil), are nil sources. The
answer is nil when a path is unaccounted for: the method's entry value reaches, an op outside the audited write list
(the rescue handler's `EXCEPT` and `RESCUE` among them) is crossed, a callee frame may overwrite the register, or the
state budget runs out.

Who reads them:

* FIXNUM_RETURN_PROOF, ARRAY_RETURN_PROOF and RETCLASS_SELF_CALL_SUPPORT (`codegen_return_analysis.rb`): the exits
  of every candidate body, `return_sources` for the class proof and `write_dominates?` for the Array proof's hops.
* DECLARED_RETURN_CHECK (`codegen_declared_returns.rb`): every exit and nested `return` of a declared method.
* The exact-class return table (`codegen_return_classes.rb`): the exits of a body and of its blocks, joined over the
  exact-class flow; the bodies that call a tracked name come from one per-op index.
* `module_function_copy_self_safe?` and `block_carrying_callers_of` (`codegen_receiver_facts.rb`).

What stays a linear walk, and why:

* `straightline_return_reg?` finds the textually preceding writer with `walk_writers` because `trace_new_target`
  and `proven_array_source`, which prove that writer, scan the same way; the IR only checks that the writer
  dominates (`write_dominates?`).
* `rescued_exception_receiver?` follows a handler's exception register back to its `EXCEPT`, a handler entry the
  normal-flow walk refuses at.
* `receiver_trace_origin` names the producer the linear receiver trace stopped at, for a diagnostic comment.

Run `ruby scripts/bc2cpp/ir_return_sites_check.rb` for the host-side regression checks.
