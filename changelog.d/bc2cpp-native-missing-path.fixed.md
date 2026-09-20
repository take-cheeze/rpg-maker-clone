- `tools/bc2cpp/bc2cpp.rb`'s two remaining bare `File.read`s over
  `NATIVE_SRCS` (`extract_native_method_names`,
  `extract_native_call_names`) now skip missing paths instead of
  raising, matching every other native-source reader in the file. A
  `git archive` export (or any checkout with uninitialized
  submodules) ships no `3rd/` contents at all; previously the whole
  run died on the first absent path, which also made the committed
  `docs/bc2cpp_coverage.txt` unreproducible from an export. Skipping
  can only ever cost a missed proof or a missed MONO->POLY flip, never
  a wrong one. No output change when every path exists.
