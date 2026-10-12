- **bc2cpp** binds `Const.name(args)` calls of native singleton functions
  (`File.exist?`, `File.file?`, `File.basename`, `Math.sin`, `Time.now`,
  `Graphics.snap_to_bitmap`, ...) on a stable class or module constant to a
  per-site cached method instead of a by-name `bc2cpp_send`, when the closed
  world proves one native registration and no Ruby definition, alias,
  visibility change, mixin or constant rebinding can precede it. The native
  function still runs in its own call frame, so argument errors, backtraces
  and blocks are unchanged. Covered by
  `scripts/bc2cpp/native_singleton_check.rb` and its mutation check; see
  `docs/adr/0416-bc2cpp-native-singleton-call.md`.
