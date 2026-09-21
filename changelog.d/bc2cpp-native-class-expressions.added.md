- bc2cpp now generates exact-class size/length fast paths for Array/Hash and
  empty? fast paths for Array/Hash/String from mruby's registered C methods.
  It also generates Hash#to_hash, Float#to_f, and Symbol#to_sym from their C
  implementations. Unsupported bodies, including String size/length's
  private character-length helper, keep normal Ruby dispatch.
