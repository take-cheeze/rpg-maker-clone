- The closed bc2cpp build keeps more core methods out of its method table: a method that only C code calls by name
  (`mrb_funcall`, `mrb_method_memo`, `mrb_func_basic_p` and the helpers that pass a name to them) is now a row, which
  those calls still find.
