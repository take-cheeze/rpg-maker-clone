- `tools/bc2cpp/bc2cpp.rb` now also infers argument types from whole-
  program call sites for method names with exactly one real definition,
  unlocking ivar embedding for a bare argument stored straight to an
  ivar outside `#initialize` (real `#initialize` calls are structurally
  invisible to this pass -- `X.new` compiles to `SEND :new`, a C-defined
  core method, never `SEND :initialize`). No effect on the two shipped
  `-compiled` gems' output (`LCF::File`, `Game::Picture`), whose real
  `#initialize` methods this can't reach either -- verified byte-for-byte
  unchanged. See `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`.
