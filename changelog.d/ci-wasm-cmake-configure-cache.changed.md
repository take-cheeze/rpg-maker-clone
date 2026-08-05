- CI's `wasm` job now caches the **CMake configure state** (`wasm-build`,
  restored before `emcmake cmake` and saved before the build) instead of
  re-probing the toolchain on every run. The emscripten configure is dominated
  by nested `try_compile` projects — ng-log alone runs 47 of them, and each is a
  full emcc invocation rather than the sub-100ms `cc` the native build pays —
  and `check_*` is a no-op once its result is in `CMakeCache.txt`, so a warm
  tree skips them outright. The key is pinned to `flake.*` and the workflow file
  with no prefix fallback, since `CMakeCache.txt` stores absolute `/nix/store`
  compiler paths; a failed reconfigure discards the tree and configures from
  scratch, so a stale cache can only cost time.
