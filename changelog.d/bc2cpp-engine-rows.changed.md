- The closed bc2cpp build keeps more engine methods out of its method table: a compiled engine method that only
  proven-receiver calls and C's `mrb_funcall` family look up (each scene's and window's `update`, `flash`, `mode`,
  `read`, `wait`, ...) is now a row of its generated table, which those calls still find.
