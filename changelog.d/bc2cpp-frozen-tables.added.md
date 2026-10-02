- `tools/bc2cpp` tracks the element classes of frozen `[..].freeze` / `{..}.freeze`
  literals (FROZEN_TABLES, ADR 0306): `TABLE[i]`, `first`/`last`/`sample`/`size`
  read the literal's slot classes, and a receiver that is only such tables is an
  exact Array/Hash. Kill switch `BC2CPP_FROZEN_TABLES=0`;
  `scripts/bc2cpp_frozen_tables_check.rb` and its mutation check cover it.
