- **bc2cpp builds** no longer read embedded instance variables as `nil`. A
  devirtualized `attr_reader`/`attr_writer` call on an embedded ivar used the
  ordinary ivar table instead of the RData struct. It affected 66 call sites,
  including the party's gold in the menu, status and shop screens, actor
  levels, message options and random-encounter counting. All ivar access now
  goes through one helper (ADR 0204). The CI check
  `scripts/bc2cpp_embedded_ivar_access_check.rb` guards it.
