- **bc2cpp closed build:** a core `alias`/`alias_method` that is registered from its
  source's definition no longer keeps the source name in the method table, so the
  closed host table goes from 741 to 727 entries (`Enumerable#inject`, `Integer#next`,
  `Hash#merge!` and others).
