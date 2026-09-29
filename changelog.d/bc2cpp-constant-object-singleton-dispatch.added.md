- bc2cpp now emits direct calls for unique public singleton methods reached
  through stable class and module constants in closed-world builds, including
  native class constants with a proven bare-name alias. This resolves 426
  shipped call sites without `mrb_funcall` in the Wio codegen.
