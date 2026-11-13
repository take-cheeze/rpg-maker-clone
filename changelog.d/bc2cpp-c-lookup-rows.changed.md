- **bc2cpp closed build:** mruby's by-name call that misses now finds `method_missing` the way the rest of its C
  by-name calls find methods, and so does mruby-io's `IO.sysopen` lookup; `BasicObject#method_missing` and
  `IO.sysopen` leave the method table (593 to 591 entries).
