- **bc2cpp**: the closed build's core-row proof no longer counts the engine's bytecode sends (the build is VM-free;
  the compiled code's own lookups are read instead), so a few more core methods leave its method table.
