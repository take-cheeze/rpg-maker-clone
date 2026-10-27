- **bc2cpp** hashes an exact Array of Fixnums natively at the start of the
  compiled `Enumerable#hash`. It no longer makes three by-name sends per
  element, and the hash values are the same as before.
  `bc2cpp_core_each_is_builtin` now interns `each` once per state. Together
  these cut optcarrot's startup (`PPU#setup_lut`'s Array-keyed Hash) by about
  0.42G instructions (2.41G to 1.99G). See `docs/bc2cpp-array-hash.md`; the
  check is `scripts/bc2cpp/array_hash_check.rb`.
