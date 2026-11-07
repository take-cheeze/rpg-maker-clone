- **bc2cpp** C++ Fiber: a step that caught an exception (`rescue`, `retry`) kept the objects its protected region had made only
  in C++ locals, which `mrb_protect_error`'s arena restore stops rooting; the next suspension stored a freed object in the frame
  (`mrb_gc_mark` assertion under `MRB_GC_STRESS`). The handler loop now spills the registers into the frame first.
