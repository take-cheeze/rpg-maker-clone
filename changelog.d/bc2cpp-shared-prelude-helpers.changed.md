- **bc2cpp: one copy of each compiled-code helper per gem on size-optimized
  builds.** The stateless helpers every shard of a compiled gem used to compile
  for itself are now `inline` under `-Os`, so the Wio Terminal image keeps one
  body per gem (about 50 KB less flash). `BC2CPP_SHARED_HELPERS=0` turns it off.
