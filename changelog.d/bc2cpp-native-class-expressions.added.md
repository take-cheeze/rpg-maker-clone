- bc2cpp now generates exact-class size/length fast paths for Array/Hash and
  empty? fast paths for Array/Hash/String from mruby's registered C methods.
  It also generates Hash#to_hash, Float#to_f, and Symbol#to_sym from their C
  implementations. Unsupported bodies, including String size/length's
  private character-length helper, keep normal Ruby dispatch.
- bc2cpp also generates exact Range#begin and Range#end accessors from mruby's
  public Range macros, while preserving dynamic dispatch for subclasses.
- Float#finite? and Float#nan? are generated from their registered C
  predicates with immediate type-tag guards.
- Float#abs is generated from mruby's conditional C body while preserving the
  original Float value on its unchanged return path.
- String#bytesize is generated from mruby's public RSTRING_LEN macro behind an
  exact String class guard.
