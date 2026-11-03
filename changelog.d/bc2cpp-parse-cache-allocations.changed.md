- **bc2cpp** compiler: a warm scan cache now skips two source parses. The names each foreign mruby `mrblib`
  source can call are cached per file, so it is no longer lexed with Prism. `NativeSigs.decls` parses only
  the cached text of the requested native table, not all 451 KB of `sig/bc2cpp/declarations.rbs`. Generated
  C++ is byte-for-byte unchanged. The sealed Optcarrot compile allocates 4.9% fewer objects with a warm cache
  and 0.1% fewer with a cold one (see `docs/bc2cpp-parse-cache-allocations.md`).
