# IR instruction checks

The host-only exact-class, container-shape, numeric-class, return-site and
origin-transfer cases run through `scripts/bc2cpp/ir_facts_check.rb`. Wrapped
loads isolate each case’s helper methods and constants while reusing compiler
libraries. The class-soundness check retains its separate compiler fixtures. They use `IrInstructionFixtures#insn` from
`scripts/bc2cpp/ir_instruction_fixtures.rb` to construct explicit bytecode and
`FixtureCheck` from `check_support.rb` for assertions and failure summaries.
The helper does not load compiler modules: each check retains its own tool
selection, including `BC2CPP_TOOLS_DIR` overrides in the container check.

Run the host-only checks with:

```bash
ruby scripts/bc2cpp/ir_facts_check.rb
ruby scripts/bc2cpp/ir_soundness_classes_check.rb
```

The soundness check always runs its hand-built bytecode cases. Setting `MRBC`
also runs the class-object compiler cases; an explicitly invalid compiler fails
instead of silently skipping. Those snippets use `FixtureCheck#compile`, each
with a fresh directory and closed world. Compilation errors remain fatal.

Instruction addresses, operands, exception handlers and Irep attributes stay
explicit in each case. These are the control-flow conditions under test and
must not be inferred by the shared helper. Argument, ivar and context checks share the
[type-check JSON runner](bc2cpp-fixture-checks.md#type-check-report-fixtures)
while retaining their enabled/disabled analysis comparisons and separate worlds.
This reorganization reduces duplicated setup, without combining those worlds
or claiming a CI speedup from file-count changes.

`MRBC=/path/to/mrbc ruby scripts/bc2cpp/ir_binary_operands_check.rb` compiles
branches, a loop, exception recovery and a captured block to real RITE bytecode.
It loads that binary into two independent trees, with disk caching disabled on
the guarded copy. Before any IR queries run on that copy, access to instruction
`args` and `raw` raises. Cold control-flow, reaching-definition, return-source
and exact-class queries must agree with the ordinary tree. Positive Integer and
Array proofs, unknown-value refusals and multiple reaching writers prevent a
vacuous comparison. This checks those shared queries; it does not claim that
every compiler pass or generated program has been proved equivalent.
The check runs in the Ruby CI job and is registered with the coverage reporter.
