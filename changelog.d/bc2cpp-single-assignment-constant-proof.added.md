- bc2cpp now propagates the class of `Klass.new` through a closed-world,
  single-assignment value constant, enabling guarded direct calls on its reads.
