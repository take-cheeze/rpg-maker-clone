- **bc2cpp**: more arithmetic and comparison sites drop their Float arms and dynamic-send fallback. `length`,
  `bytesize` and `to_i` results now count as Integers (an audited native table), declared Integer and Float
  parameters count as numeric operands past their entry check, and the chipset tile geometry, transition and
  event-signature methods declare their Integer parameters (`sig/bc2cpp/declarations.rbs`).
