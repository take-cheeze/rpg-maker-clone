- **A binary <-> text converter for LCF project files**, `scripts/
  lcf_text_convert.rb`. Converts a `.ldb` (database), `.lmu` (map unit) or
  `.lsd` (save) to a human-editable YAML form (`to_text`) and back
  (`to_binary`), schema-checked against `mruby-lcf/mrblib/schema.rb` in both
  directions — an edited file is validated (unknown fields, wrong types,
  malformed event/move-command entries, every problem reported at once) and
  only written once it passes, and an unedited file round-trips byte-exact.
  A `check` subcommand validates without writing. `.lmt` (the map tree) is
  text-exportable but not yet binary-writable — its multi-section format has
  no writer yet, reported plainly rather than attempted. See
  `docs/adr/0055-lcf-text-convert.md`. Covered end to end, against synthetic
  fixtures (no test-bed project required), by `scripts/
  lcf_text_convert_check.rb`.
