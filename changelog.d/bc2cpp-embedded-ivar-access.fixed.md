- **bc2cpp**: every instance-variable access in generated code now goes
  through one helper that picks the ivar table or the embedded RData struct,
  so no emitter can read an embedded ivar as `nil` again. It also closes two
  latent holes: a runtime-def/EXEC body no longer compiles struct access
  against the wrong `self`, and an ivar a subclass method touches is never
  embedded. The CI check `scripts/bc2cpp_embedded_ivar_access_check.rb`
  compiles and runs a fixture against real mruby. See ADR 0205.
