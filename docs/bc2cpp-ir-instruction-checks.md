# IR instruction checks

The exact-class, container-shape and class-soundness checks retain independent
entrypoints and fixture programs. They use `IrInstructionFixtures#insn` from
`scripts/bc2cpp/ir_instruction_fixtures.rb` to construct explicit bytecode and
`FixtureCheck` from `check_support.rb` for assertions and failure summaries.
The helper does not load compiler modules: each check retains its own tool
selection, including `BC2CPP_TOOLS_DIR` overrides in the container check.

Run the host-only checks with:

```bash
ruby scripts/bc2cpp/ir_exact_types_check.rb
ruby scripts/bc2cpp/ir_container_shapes_check.rb
ruby scripts/bc2cpp/ir_soundness_classes_check.rb
```

The soundness check always runs its hand-built bytecode cases. Setting `MRBC`
also runs the class-object compiler cases; an explicitly invalid compiler fails
instead of silently skipping. Those snippets use `FixtureCheck#compile`, each
with a fresh directory and closed world. Compilation errors remain fatal.

Instruction addresses, operands, exception handlers and Irep attributes stay
explicit in each case. These are the control-flow conditions under test and
must not be inferred by the shared helper. Argument and ivar checks retain
separate compilation/report pipelines because their enabled/disabled analysis
comparisons and poisoning scenarios require different whole-program worlds.
This reorganization reduces duplicated setup, without combining those worlds
or claiming a CI speedup from file-count changes.
