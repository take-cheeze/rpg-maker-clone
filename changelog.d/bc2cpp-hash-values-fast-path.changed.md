- bc2cpp now lowers exact base `Hash#values` calls through mruby's public
  `mrb_hash_values` API, retaining Ruby dispatch for subclasses and other
  receiver types.
