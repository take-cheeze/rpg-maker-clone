- **bc2cpp**: psp, wio and maix builds now compile only the profiled hot
  methods to C++ (`BC2CPP_HOT_ONLY`). `tools/bc2cpp/hot_methods.txt` lists
  them. Every other method stays mruby bytecode, and bc2cpp treats it as a
  method it could never compile: no `_impl`, no registration, and callers
  reach it by ordinary dispatch. The list covers 98% of compiled-code Ir.
  Across the three compiled gems the `-Os` text drops from 4.1 MB to
  0.56 MB. On wio about 0.38 MB of bytecode that used to be stripped is
  kept, so wio saves about 3.1 MB of flash. Engine Ir changes by −1.8% to
  +1.9% across the measured scenarios. `scripts/bc2cpp_hot_profile.rb` regenerates
  the list from callgrind runs. Desktop, wasm and android still compile
  everything. `BC2CPP_HOT_ONLY=1` builds the desktop binary in the same mode
  for testing. See ADR 0214.
