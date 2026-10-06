- **bc2cpp** `bc2cpp_slow_lt`/`le`/`gt`/`ge` mirror Comparable's body for String and
  Symbol receivers and raise the proven NoMethodError for every receiver outside
  Integer, Float, Numeric, String, Symbol and Hash when the closed world shows no
  other answerer; a Hash receiver still dispatches by name (ADR 0362).
