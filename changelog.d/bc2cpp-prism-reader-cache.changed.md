- **bc2cpp** compiler: a warm scan cache no longer parses `mruby-rpg2k`, `mruby-lcf` or the rgss `mrblib`
  with Prism. The class world (`ClassWorld.build_files`), each file's `initialize`-defining classes
  (`DispatchTargetSources.file_initializers`) and the Ruby half of the rgss constructor scan are cached as plain
  data, keyed by the files' digests and the Prism version. Generated C++ is byte-for-byte unchanged. The sealed
  Optcarrot compile allocates 8.5% fewer objects with a warm cache and 0.03% more with a cold one (see
  `docs/bc2cpp-prism-reader-cache.md`).
