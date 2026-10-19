- **bc2cpp** dominance checks now ask the bytecode IR instead of re-deriving
  it. The Fixnum proof's nested-block barrier is
  `BytecodeIR.own_upvar_written_regs` (level-aware), so a register only a
  deeper block's SETUPVAR names (class bodies, outer blocks) is no longer
  opaque. `fixnum_interval`, `guarded_game_integer_range` and the
  `step`/`upto`/`downto` literal test ask `BytecodeIR.write_dominates?` per
  hop (catch-handler edges and callee-frame clobbers included), and
  `fixnum_proof_region_ok?` is a thin wrapper over the IR's predecessor
  graph; the hand-built branch-edge map is gone.
