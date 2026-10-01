- **bc2cpp LCF row flow** (ADR 0294): a whole-program class flow proves which values are an
  `LCF::Database`, a table or a row, so `db[:x][i][:y]` becomes exact-class, guard-free direct calls and a
  field read gets its schema class (Integer/String/Array/Hash/nil). `LCF::Array2D#[]=` now keeps only nil,
  bytes or a row over the table's own schema (a foreign-schema row is re-read through the table schema).
