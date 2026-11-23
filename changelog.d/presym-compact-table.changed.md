- Every mruby build now stores its presym (symbol) names in a compressed table that is
  decoded on demand. This saves about 44 KB of flash on Wio Terminal. Set
  `MRB_PRESYM_COMPACT=0` when building to restore the plain table.
