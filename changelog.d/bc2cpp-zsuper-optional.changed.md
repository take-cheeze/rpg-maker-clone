- **bc2cpp compiles a bare `super` in a method with optional parameters.** It
  becomes a direct call of the superclass `_impl` with every parameter, as
  the bare `super` passes them, when the superclass method takes that many
  arguments. `LCF::SaveData#initialize(io = nil)` now compiles. bc2cpp's
  "skipped" report also names each method's unsupported construct.
