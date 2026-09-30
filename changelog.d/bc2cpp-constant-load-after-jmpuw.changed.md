- **bc2cpp:** a constant load that follows a `break` inside a `begin`/`rescue`
  loop (a `JMPUW`) is now recognised as a straight-line load, so
  `LCF.read_ber`/`LCF.write_ber` calls in those loops call their compiled
  singleton method directly instead of dispatching by name. Covered by
  `scripts/bc2cpp_constant_singleton_check.rb`.
