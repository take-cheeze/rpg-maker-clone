- **bc2cpp** `Irep#last_writer`/`#source_writer`/`#each_with_op` and
  `IrepScans#walk_writers`/`#preceding_run` now delegate to
  `BytecodeIR::Program`, which owns the one indexed backward walk;
  `tools/bc2cpp/bytecode_ir_ops.rb` is the shared home of opcode-meaning sets
  (ADR 0493). Generated output is unchanged.
