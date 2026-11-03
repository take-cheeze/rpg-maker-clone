- **bc2cpp** allocates fewer host objects: the source scans stat each file list
  once per compile, hot emitters name registers from a frozen table, and
  `inheriting_subclasses`, `direct_call_args`, `strict_hint_wrap`,
  `poly_diagnostic` and `NativeDirect.strip_comments` stop rebuilding
  intermediates. The sealed Optcarrot compile allocates about 9.5% fewer host
  objects; the generated C++ is unchanged. See
  [small allocation fixes](docs/bc2cpp-small-allocations.md).
