- **bc2cpp** native-source scanners (`NativeExpressionDevirt.brace_body` and
  `split_call_arguments`) read bytes instead of one-character Strings, and the
  ROM-table, function-definition and macro-call scans use block-form `scan`
  instead of an Enumerator. The sealed Optcarrot compile allocates about 6.8%
  fewer host objects; the scan results and generated C++ are unchanged. See
  [devirt scan allocations](docs/bc2cpp-devirt-scan-allocations.md).
