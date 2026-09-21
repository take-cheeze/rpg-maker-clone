- bc2cpp now devirtualizes `Hash#key?` for exact base Hash receivers through
  mruby's native lookup helper, with dynamic dispatch retained for overrides
  and other receiver classes.
