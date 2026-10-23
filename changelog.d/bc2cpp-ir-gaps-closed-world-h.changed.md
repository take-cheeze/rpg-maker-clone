- **bc2cpp**: the closed-world scans (`ClosedWorld#scan_closed_world` and its
  `scan_*` helpers, `def_method_body`, the String argument gap test) and
  `YieldReach#compute_proc_free_ivar` read instructions through the
  `BytecodeIR::Program` helpers instead of the raw `irep.instructions` list; the
  now-unused `BytecodeIR::Window` module is removed. Generated output is
  unchanged.
