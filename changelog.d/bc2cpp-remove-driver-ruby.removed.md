- **bc2cpp:** remove the Ruby driver source of ENUM_STEP, the generated per-method drivers (`EnumDriverGen`), and the
  enum-step fixtures that asserted on them. Guarded core methods keep their saved body, which the Fiber path runs
  through a VM frame. `BC2CPP_ENUM_STEP` still gates the resumable variants.
