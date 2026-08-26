- **RPG2k's Scene::Map named-graphic caches (CharSet/Picture/Backdrop/
  Monster/Animation/BattleCharSet/System2) now evict least-recently-used
  entries once over a per-category byte budget, instead of growing
  forever.** Each of the seven caches used to be a plain Hash that only
  ever gained entries -- every uniquely-named graphic a session ever
  showed, across every map and battle for the whole play session, stayed
  decoded in memory permanently, since `Scene::Map` is a session-long
  singleton only replaced at New Game/Continue, not on an ordinary map
  transfer. Each cache is now a small `LRUBitmapCache` bounded by estimated
  decoded pixel bytes (`width * height * 4`, this build's fixed ARGB8888
  decode format); an evicted entry is simply reloaded and re-cached the
  next time its name comes up, exactly as a genuine cache miss already
  was, so this is a size-bound fix with no behavior change on the fast
  path. `#cached_bitmap`'s own call sites needed no changes -- the new
  class implements the same `key?`/`[]`/`[]=` surface a plain Hash did,
  including direct cache manipulation from existing tests. Note this
  bounds *native*-heap growth (`Bitmap`'s pixel buffer is a
  `std::vector<uint8_t>` using the ordinary C++ allocator, not the mruby
  arena), a different budget than the PSP mruby-arena work elsewhere in
  this series -- see docs/adr/0047-psp-memory-budget.md.
