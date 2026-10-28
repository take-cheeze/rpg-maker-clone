- **bc2cpp closed build:** the engine reads a few names where a core class shares them
  (`MoveRoute#cursor`/`#advance` for `index`/`step` on a route, `CommonEventRecord#lcf_chunk`
  for `chunk`, a local for `RPG2k#start_new_game`'s `state`), so the Enumerator-free proof
  (`tools/bc2cpp/core_enumerator_free.rb`) holds and the 15 methods of mruby-enumerator's Fiber
  machinery (`Enumerator#each`, `Kernel#to_enum`, `Enumerable#zip`, ...) leave the closed
  method tables.
