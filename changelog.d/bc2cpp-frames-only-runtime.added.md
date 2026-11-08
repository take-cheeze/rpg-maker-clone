- **Build:** an opt-in frames-only archive derived from the closed bc2cpp build replaces mruby's `vm.c` with
  `tools/bc2cpp/runtime/vm_frames.cxx`: native-callee frames, funcall and yield, and no path into bytecode (the host
  sweep passes with it). The default build is unchanged.
