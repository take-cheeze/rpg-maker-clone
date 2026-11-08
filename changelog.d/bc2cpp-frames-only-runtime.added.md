- **Build:** the closed bc2cpp build no longer links mruby's `vm.c`; `tools/bc2cpp/runtime/vm_frames.cxx` provides
  the native-callee frames, funcall and yield, with no bytecode interpreter entry (`mrb_vm_exec` and nine more
  symbols have no definition). Other build targets keep `vm.c`.
