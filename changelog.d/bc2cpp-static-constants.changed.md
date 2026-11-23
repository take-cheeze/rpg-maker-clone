- **bc2cpp**: the constant caches and lexical-scope lookups are ROM rows read by one shared function each
  instead of a generated function per (scope, name), and their slots are sized by the constants a gem reads.
  On the Wio build this saves 81,684 B of flash and 11,012 B of static RAM. `BC2CPP_STATIC_CONSTANTS=0`
  restores the generated functions.
