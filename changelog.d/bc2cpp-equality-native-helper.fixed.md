- bc2cpp now routes unmatched bytecode equality shapes through mruby's
  `mrb_equal` helper when the closed-world registry proves there is no Ruby
  `==` override, preserving Integer comparisons with BigInt and other numerics.
