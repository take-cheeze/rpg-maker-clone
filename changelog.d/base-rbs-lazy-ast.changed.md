- Native base RBS generation skips Clang AST extraction and JSON parsing for
  files without registered function bodies needing return analysis, while
  retaining same-file helper analysis and per-file result isolation.
