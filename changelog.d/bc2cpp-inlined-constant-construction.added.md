- bc2cpp now traces constructor constants through inlined bytecode and directly
  constructs proven RGSS `Table` values, plus standard `String` and `NameError`
  objects when their runtime class identities and constructor chains match.
