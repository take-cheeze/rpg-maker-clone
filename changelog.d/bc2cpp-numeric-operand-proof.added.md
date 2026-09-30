- **bc2cpp** proves more arithmetic and compare operands to be Integer or Float
  (instance variables kept numeric by `@i += 1`, arguments every call site
  passes a number, name-agreed return values, layout constants, captured
  locals) and drops the dynamic `bc2cpp_send` from those guarded arms in favour
  of mruby's overflow-aware numeric helpers. See ADR 0276.
