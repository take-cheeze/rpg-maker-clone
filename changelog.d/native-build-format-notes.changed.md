- **`scripts/native-build-without-nix.bash` now says how to check formatting.**
  The `build` job runs pre-commit as a background step, so a formatting slip
  fails `build` with no compile error in the log. The working local check is
  `clang-format --dry-run --Werror <file>` run *inside* the repository —
  clang-format locates `.clang-format` by walking up from the file's own
  directory, so checking a copy under `/tmp` falls back to LLVM defaults
  (`PointerAlignment: Right` where this repo sets `Left`) and fabricates a diff
  of hundreds of unrelated lines. Also recorded: the narrow real version
  difference (clang-format 18 flags three pre-existing lines in
  `mruby-rgss/src/lib.cxx` that CI accepts), and why a line-length grep is not a
  substitute — several tracked files hold lines clang-format cannot break, and
  `awk` counts bytes, so an em-dash makes a legal line look over-length.
