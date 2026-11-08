- **bc2cpp host entry calls catch a raise as a typed C++ exception** (VM-free
  plan, Phase 3/5): `bc2cpp_entry_*` in `<gem>_entry.h` no longer calls
  `mrb_protect_error` (193K calls per sweep, one per frame); it catches the
  thrown `mrb_jmpbuf*` itself with the same call-frame, arena and `M->exc`
  handling, and the header requires `MRB_USE_CXX_EXCEPTION`. The dead
  `mrb_exec_irep` extern is gone from generated code. `mrb_protect` and
  `mrb_exec_irep` baselines in `vm_free_inventory_check.rb` drop to 10 and 1,
  and `vm_unreachable_check.rb` pins who may still reference `mrb_protect_error`.
