- **bc2cpp** `bc2cpp_slow_xor`, `bc2cpp_slow_rshift` and `bc2cpp_slow_round` no
  longer dispatch by name when the closed world proves only core classes answer
  `^` (Integer, nil, true, false), `>>` (Integer) or `round` (Integer, Float):
  the helper mirrors each class's body and any other receiver raises the proven
  NoMethodError. `&`, `|`, `<<`, `%`, `-@`, `zero?` and `===` stay open (ADR 0364).
