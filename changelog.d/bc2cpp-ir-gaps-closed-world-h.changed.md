- **bc2cpp**: the closed-world scans (`ClosedWorld#scan_closed_world`,
  `def_method_body`, the literal-Symbol and String argument readers) and
  `YieldReach#compute_proc_free_ivar` read instructions through the
  `BytecodeIR::Program` helpers instead of the raw `irep.instructions` list; the
  now-unused `BytecodeIR::Window` module is removed. Generated output is
  unchanged.
