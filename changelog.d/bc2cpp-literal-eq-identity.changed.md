- **bc2cpp**: `x == :sym`, `x == nil`, `x == true/false` and `x == 1` compile to a word compare (a Float
  compare for `1 == 1.0`) when no `==` in the program can answer otherwise, about 13 KB less Wio flash
  (`BC2CPP_LITERAL_EQ_IDENTITY=0` keeps the full compare).
