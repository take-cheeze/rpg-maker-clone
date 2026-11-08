- The closed build's method table drops compiled entries whose names only a
  non-lookup used to keep: the Proc `arity`/`parameters` stand-in read, `attr_*`
  and `to_enum` symbols and aliases in core Ruby, `MRB_OPSYM` / `MRB_IVSYM`
  macro arguments, native `mrb_get_args` formats and `strcmp` operands, and the desktop application's `src/`.
