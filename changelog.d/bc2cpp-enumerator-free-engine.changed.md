- **bc2cpp closed build:** the engine reads a route's cursor and steps it through
  `MoveRoute#cursor`/`#advance`, and the common-event chunk through `CommonEventRecord#lcf_chunk`,
  names no core class shares, so the Enumerator-free proof (`tools/bc2cpp/core_enumerator_free.rb`)
  holds and the 15 methods of mruby-enumerator's Fiber machinery (`Enumerator#each`,
  `Kernel#to_enum`, `Enumerable#zip`, ...) leave the closed method tables.
  The host method table goes from 1290 to 1272 entries (`scripts/bc2cpp/method_table_threshold.txt`).
