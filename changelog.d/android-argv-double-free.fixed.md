- Fixed an intermittent native crash (`Scudo ERROR: invalid chunk state`,
  later confirmed with AddressSanitizer to be a double-free) at the end of
  every Android run. `gflags::ParseCommandLineFlags`'s `remove_flags=true`
  fixup mutates `argv` in place — it overwrites the last recognised flag's
  slot with a copy of `argv[0]`'s pointer rather than shifting every
  element — which is harmless everywhere else this engine ships (`argv`
  there came from the OS/libc, which never frees it), but not on Android:
  SDL's own JNI glue (`nativeRunMain`, `3rd/SDL/src/core/android/
  SDL_android.c`) synthesizes `argv` from Java and frees every element
  itself once `main()` returns, still counting up to its own original
  (larger) `argc` — so it ends up freeing that duplicated pointer twice.
  `src/main.cxx` now parses a copy of `argv` instead, so gflags' fixup
  lands on its own local array and SDL's is never touched (docs/adr/
  0058-android-port.md has the full investigation).
