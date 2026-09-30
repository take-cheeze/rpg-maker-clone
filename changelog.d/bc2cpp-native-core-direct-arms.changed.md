- **bc2cpp** calls verified mruby core natives directly behind exact
  builtin-class guards: `Array#join` (no argument, or a nil/String separator),
  `#shift`, `#compact`, `#index`, `String#bytes` and `Integer#inspect`. Every
  row is re-audited against the real mruby sources on each compile (registration,
  registered body, public API), so an mruby upgrade that changes one drops it and
  fails `scripts/bc2cpp_native_core_direct_check.rb`; outside Ruby definitions
  are attributed to their class (`tools/bc2cpp/foreign_definers.rb`). The
  coverage report now separates definitions covered by the RGSS arms
  (`native_direct`, 772) from the rest of `native_or_uncompiled` (1,033 to 261).
  See `docs/adr/0257-bc2cpp-native-core-direct-arms.md`.
