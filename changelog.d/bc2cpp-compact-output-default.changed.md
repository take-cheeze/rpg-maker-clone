- **bc2cpp** (ADR 0463): generated C++ is compact by default: the per-site `//` proof comments are stripped from
  stdout (about a quarter of the engine's generated source). `bc2cpp.rb --annotated` keeps them, and every check and
  tool that reads them passes it. `BC2CPP_COMPACT_OUTPUT` is removed.
