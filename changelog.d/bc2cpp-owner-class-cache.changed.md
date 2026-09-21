- bc2cpp resolves each exact-class guard's owner class once per VM through a
  cached file-scope helper instead of re-running the chained `mrb_const_get`
  and `mrb_intern_cstr` lookups on every call, and resets the cache in each
  compiled gem's `gem_final`.
