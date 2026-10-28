- **bc2cpp**: the closed proof no longer counts an identifier-shaped string literal as a method lookup when it is
  only compared, used as a hash key or printed (IDENT_USES, the FRAGMENT_USES flow applied to exact names). It
  applies only while SYMBOL_USES proves every by-name lookup in the closed bytecode takes a literal.
