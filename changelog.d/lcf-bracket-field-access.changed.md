- **LCF fields are read with `[]` only.** `LCF::Array1D`, `LCF::Sections` and
  `LCF::File` no longer answer `row.hp_max`, `tree.initial` or `db.actor`
  through `method_missing`, and no longer answer `respond_to?(:field)` through
  `respond_to_missing?`; every caller in the runtime, the host scripts and the
  tests now reads `row[:hp_max]` / `db[:actor]`, and probes a field with
  `LCF.field?(row, :hp_max)` (backed by the new `Array1D#field?`,
  `Sections#field?` and `File#field?`). `LCF::File#delete` forwards to the root
  record. A stray dotted read now raises `NoMethodError`. Under CRuby the
  harnesses stop logging `screen transition defaults unreadable` (the old
  `db.system` reached `Kernel#system` there). Pinned by the new
  `scripts/lcf_bracket_access_check.rb`. See ADR 0213.
