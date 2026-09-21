- bc2cpp now derives the exact-Array, one-argument `push` path from mruby's
  registered C wrapper and public `mrb_ary_push` helper; other arities retain
  normal method dispatch.
