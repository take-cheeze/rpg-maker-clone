- **bc2cpp** now inlines the common case of Array `<<`/`push`, `a[i] = v` and
  same-length `a[i, n] = rpl`. It also gives `rotate!` an audited exact-Array
  arm, compares two Integers for `!=` without an `Integer#==` send, and reads
  an Integer receiver's class from its tag in POLY chains
  (`docs/bc2cpp-array-write-inline.md`). Each fallback is the library call it
  replaces. Checked by `scripts/bc2cpp/array_write_inline_check.rb`.
