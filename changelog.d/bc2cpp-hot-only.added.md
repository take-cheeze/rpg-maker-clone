- **bc2cpp**: psp, wio and maix builds now compile only the profiled hot
  methods to C++ (`BC2CPP_HOT_ONLY`). `tools/bc2cpp/hot_methods.txt` lists
  them. Every other method stays mruby bytecode, and bc2cpp treats it as a
  method it could never compile: no `_impl`, no registration, and callers
  reach it by ordinary dispatch. Across the three compiled gems the `-Os`
  text drops from 5.0 MB to 0.70 MB. On wio about 0.37 MB of bytecode that
  used to be stripped is kept. `scripts/bc2cpp_hot_profile.rb` regenerates
  the list from callgrind runs. Desktop, wasm and android still compile
  everything. `BC2CPP_HOT_ONLY=1` builds the desktop binary in the same mode
  for testing. See ADR 0214.
