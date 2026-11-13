- **bc2cpp**: the Fiber-step variants of compiled mruby core methods send their own methods through the closed-world
  owner call instead of by name, so 45 more core methods leave the closed build's method table.
