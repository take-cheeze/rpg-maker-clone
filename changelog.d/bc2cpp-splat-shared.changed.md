- **bc2cpp** (SPLAT_SHARED): a guarded `send(*list)` reads its name and arguments from `list` in place when it is
  an Array of immediates no longer than the longest arm's list; ARYCAT's copy is made only for the original send.
  Optcarrot's `send(*DISPATCH[@opcode])` no longer allocates an Array per emulated instruction, which removes its
  steady-state GC: 180 frames, 3.47 s to 3.10 s wall. `BC2CPP_SPLAT_SHARED=0` keeps the copy. Covered by
  `scripts/bc2cpp/computed_send_check.rb`.
