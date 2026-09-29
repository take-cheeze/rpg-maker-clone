- **bc2cpp** native-source scans (`NativeExpressionDevirt`) are about 20% faster
  end to end: each source is read once, macro scans skip files that lack the
  macro, and the brace/argument scanners no longer index non-ASCII text in
  O(n). Generated output is byte-identical.
