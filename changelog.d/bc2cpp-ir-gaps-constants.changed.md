- **bc2cpp**: the constant-argument, constant-site cache, unique class name and report scans read the bytecode IR
  (`each_source`, `each_with_op`) instead of the raw `irep.instructions` list. Analysis only: the generated C++ is
  unchanged.
