- **bc2cpp** now stores eligible statically named ivars on wired RData-backed
  classes in GC-traced `mrb_value` slots. Dynamic ivar names retain the normal
  ivar-table fallback, and save/load accessors no longer require typed fields.
  The mruby runtime support is reproducibly applied from the project's patch
  chain.
