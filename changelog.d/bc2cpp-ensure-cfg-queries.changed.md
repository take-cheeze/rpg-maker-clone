- **bc2cpp:** The ensure recognizer's jump-crossing rules, the ensure body's
  escaping-branch rule, `jmpuw_is_plain_jump?` and the rescue class-chain walk
  now use `BytecodeIR` queries (`region_crossings`, `branches_onto`,
  `branches_escaping`, `handlers?`, `run_of_op`) instead of hand-rolled loops.
  Decision-preserving: generated output is byte-identical, and the new
  `scripts/bc2cpp_rescue_shadow_check.rb` compares the old and new answers on
  every recognizer call over the real closed world.
