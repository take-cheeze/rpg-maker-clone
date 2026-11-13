- **bc2cpp:** the closed build's own `mrb_funcall` now finds a method's row, as
  mruby's `vm.c` does, so a native's by-name call of a name whose entry was
  dropped no longer raises `NoMethodError`.
