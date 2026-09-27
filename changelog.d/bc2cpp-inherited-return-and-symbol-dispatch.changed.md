- bc2cpp's closed-world analysis now follows proven inherited methods for
  return-class hints and `&:method` loop inlining, preserving exact-class guards
  and dynamic fallbacks where required. Runtime mixin changes outside recognized
  class bodies conservatively disable these proofs.
