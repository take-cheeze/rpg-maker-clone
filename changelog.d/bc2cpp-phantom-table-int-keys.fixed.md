- **bc2cpp**: the closed build's respond_to? table of left-out methods (RESPOND_TO_PHANTOM) is keyed by the symbol's
  number instead of the Symbol. mruby hashes a Symbol key from bits that 64-bit word boxing leaves empty, so the
  table of every left-out entry was one hash bucket, and each `respond_to?` miss or entry registration scanned it:
  the Nepheshel 1-frame load had grown from 0.37 G to 1.37 G instructions.
