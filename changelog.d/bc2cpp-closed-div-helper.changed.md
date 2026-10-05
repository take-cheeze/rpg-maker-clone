- **bc2cpp** `bc2cpp_slow_div` no longer dispatches by name when the closed world
  proves only Integer and Float answer `/`: other receivers raise the proven
  NoMethodError directly, removing 272 generated sites from the by-name census
  (ADR 0359).
