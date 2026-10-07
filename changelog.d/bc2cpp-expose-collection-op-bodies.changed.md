- **bc2cpp** `bc2cpp_slow_sub_f`, `bc2cpp_slow_and`, `bc2cpp_slow_or` and
  `bc2cpp_slow_lshift` drop their by-name else when only core classes and the
  mruby gems that are linked answer the operator. The new
  `patches/mruby-expose-collection-op-bodies.patch` exports the bodies of
  `Array#-`, `Array#&`, `Array#|`, `String#<<` and `IO#<<` (the interpreter's
  behaviour is unchanged); it is applied last by every mruby build. See
  `docs/adr/0366-bc2cpp-expose-collection-op-bodies.md`.
