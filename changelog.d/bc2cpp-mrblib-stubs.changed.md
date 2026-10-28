- **Closed builds ship compiled methods' mrblib bodies empty.** With the
  compiled gems in the build, the engine gems' mrblib is a build-time copy in
  which every compiled method that never runs as bytecode keeps only its
  `def` line, with a body of `raise ScriptError`. A body that may run while
  mrblib loads, one a `module_function` or `alias` copies, and guarded
  entries keep their bytecode. See `docs/bc2cpp-mrblib-stubs.md`.
