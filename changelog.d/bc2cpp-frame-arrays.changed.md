- **bc2cpp**: `x, y = f(...)` with `f` a compiled method whose every return is
  a fresh literal Array passes the values through a frame-local buffer instead
  of building the Array (`MULTI_RETURN`, `BC2CPP_MULTI_RETURN=0` turns it off),
  and `[a, b].min` / `.max` is one helper call with no Array for an all-Integer
  list (`LITERAL_MINMAX`, `BC2CPP_LITERAL_MINMAX=0`). A headless battle makes
  40% fewer Arrays and a new game 31% fewer; the Wio Terminal image is 2.3 KB
  smaller.
