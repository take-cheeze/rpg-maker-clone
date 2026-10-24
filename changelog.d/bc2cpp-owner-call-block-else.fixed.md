- **bc2cpp: a block send whose guard chain names a Ruby definer no longer
  compiles its else to a proven NoMethodError.** When the closed world lifted
  the outside-definer refusal for such a send, the generated
  `bc2cpp_nomethod` else was meant to become the owner call over the outside
  classes (Array, Hash, ...), but the pattern that found it missed the
  ` @ site` part of the marker, so `@items.each(&blk)` in a class that also
  defines `each` raised at run time. Covered by
  `scripts/bc2cpp/explicit_block_arg_direct_check.rb`.
