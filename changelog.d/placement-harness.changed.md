- **bc2cpp** gains the gate harness that any in-frame object placement must pass (`scripts/bc2cpp/placement_harness_check.rb`,
  `docs/bc2cpp-placement-harness.md`): a static gate on the escape and immediate-ivars facts, a frame-exit heap tripwire,
  a GC at frame exit, and a sanitizer run. The placement itself is not implemented, and the experimental flag
  `BC2CPP_EXPERIMENTAL_INFRAME_PLACEMENT=1` is refused. Shipped code generation is unchanged.
