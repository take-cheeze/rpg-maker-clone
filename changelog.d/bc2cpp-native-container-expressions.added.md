- bc2cpp now generates exact-class size fast paths for Array/Hash and
  empty? fast paths for Array/Hash/String from mruby's registered C methods.
  Unsupported bodies, including String#size's private character-length
  helper, keep normal Ruby dispatch.
