- **bc2cpp**: the inlined-loop element check and the class-object argument check read the IR write facts
  (`BytecodeIR.own_upvar_written_regs`, `may_write?`) instead of a hand-rolled write set and a reaching-definitions
  walk per instruction. On the engine's Ruby sources every loop-flow decision is unchanged, and so is every
  class-object stability answer a `new` site reads. New check `scripts/bc2cpp/loop_element_writes_check.rb`.
