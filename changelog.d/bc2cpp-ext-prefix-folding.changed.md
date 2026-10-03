- **bc2cpp** folds the `EXT1`/`EXT2`/`EXT3` operand-width prefixes into the
  instruction they widen, so no analysis refuses an iseq for carrying one:
  +138 constant pools and 21 fewer by-name sends in the wio closed world, and
  a method with more than 255 registers now compiles. `BC2CPP_EXT_PREFIX=0`
  restores the previous output byte for byte (ADR 0320).
