- **bc2cpp**: the closed build's operator slow paths (a non-Integer `a << b`, `+`, `-`, ...) find their method through
  the owner call's inline cache again instead of a by-name lookup on every call. A New Game run does half as many
  method-table lookups (127k to 65k over 3000 frames).
