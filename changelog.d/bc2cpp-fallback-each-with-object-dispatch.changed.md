- bc2cpp now devirtualizes proven Array elements inside fallback
  `each_with_object` blocks, retaining an exact class guard and Ruby dispatch
  fallback for unexpected elements.
