- **bc2cpp rescue/ensure boundaries are a typed C++ catch** (VM-free plan,
  Phase 3): generated code calls one `bc2cpp_protect` (a `catch (mrb_jmpbuf*)`
  that restores the call-info stack, arena and `M->exc` as the VM's protect
  call did) instead of `mrb_protect_error`, and every arena root goes through
  `bc2cpp_root` / `bc2cpp_arena_keep`. `mrb_protect` and `mrb_gc_protect` sites
  in the closed build drop sharply; `scripts/bc2cpp/protect_cxx_check.rb` runs
  the rescue/ensure shapes interpreted and compiled, also under GC stress.
