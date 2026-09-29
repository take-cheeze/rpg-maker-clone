- **bc2cpp** `Irep#each_with_op` and `BytecodeIR::Program#adjacent_pairs` visit
  only the instructions with the wanted ops through a per-irep op index
  instead of testing every instruction on every call. Output is byte-identical.
