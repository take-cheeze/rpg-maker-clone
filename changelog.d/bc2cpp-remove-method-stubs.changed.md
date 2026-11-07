- **bc2cpp**: the closed build no longer empties compiled method bodies in the engine and core mrblib copies. The stub
  rewrite (`bc2cpp_stub_mrblib`, `bc2cpp_stub_core_mrblib`) and the stub manifests are gone, and the load plan drops no
  defs for them. `tools/bc2cpp/mrblib_stubs.rb` remains only for the helpers the load plan still reads.
