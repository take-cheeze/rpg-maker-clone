- **bc2cpp** (ADR 0294 addendum): the exact-class flow reads LCF database fields by their schema class, so
  `row[:name].empty?`, `db[:term][:gold].to_s` and ivars stored from field reads drop their class chain and
  by-name else.
