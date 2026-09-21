- bc2cpp now generates exact-class size fast paths for Array/Hash and
  empty? fast paths for Array/Hash/String from mruby's registered C methods.
  It also generates Hash#to_hash from its C implementation. Unsupported
  bodies, including String#size's private character-length helper, keep
  normal Ruby dispatch.
