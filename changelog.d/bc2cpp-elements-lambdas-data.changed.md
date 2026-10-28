- **bc2cpp**: the 18 `LCF::Schema` `elements:` lambdas are folded to data in builds with compiled gems (not wio, which
  keeps its blob). `mruby-lcf/gen_schema_tables.rb` writes the field tables as bytes in `.rodata` (13 KB with the string
  pool) and a copy of `schema.rb` in which each lambda is its table number; `LCF.elements_of` builds a record type's
  Hash on its first read through the native `LCF.schema_table` (`src/schema_tables.hxx`, 2 KB), so nothing is built at
  load and no bytecode runs for it (the lambda and `Proc#call` starts are gone). The schema's irep shrinks from 38 KB
  to 14 KB: 8 KB less in all. `scripts/bc2cpp/lcf_schema_tables_check.rb` compares every table with the lambda's Hash
  under a real mruby. See `docs/bc2cpp-vm-entries.md`.
