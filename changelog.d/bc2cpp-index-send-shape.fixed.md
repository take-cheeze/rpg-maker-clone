- Fix the sweep `NoMethodError: undefined method '[]' for String` after
  eliminating `[]` from the method tables: the verdict proved receiver
  classes but the generator only devirtualizes 1-argument `[]` sends, so 17
  two-index engine slices (game-title reader, message reveal, shop/scroll
  windows) fell through to a by-name lookup with no table entry. They are
  now 1-argument Range sends through the same native path, and the verdict
  refuses the name while the closed world's bytecode holds a generic-send
  `[]`/`[]=`, failing safe instead of shipping the raise.
