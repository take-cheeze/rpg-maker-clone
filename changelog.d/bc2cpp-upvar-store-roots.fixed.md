- **bc2cpp**: a block's store to a captured local now roots the value, so a String or
  Array kept only in such a local is no longer collected while the iterator runs
  (`min_by { |x| x.to_s }` under GC pressure; ADR 0272).
