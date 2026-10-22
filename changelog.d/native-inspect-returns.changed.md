- **bc2cpp:** the native return analysis models struct fields, nil tests and
  string assignments, so `mrb_obj_inspect` and `mrb_inspect` return String.
  `Kernel#inspect` stays untyped until `Range#inspect`'s element result is
  decided.
