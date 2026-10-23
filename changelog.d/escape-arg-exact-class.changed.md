- The shared escape analysis judges a value passed as an argument with the
  class it is known to have at the call site. A callee that only reads
  attributes of its argument (`o.x` where `o` is a `Pt`) resolves `x` on that
  class instead of on every `x` in the program, so the caller's object no
  longer counts as escaping. Storing, returning or passing the argument on
  still escapes.
