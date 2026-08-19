- **`LCF.encode` can now re-encode event-page command lists and move
  routes** (`:event` / `:move_commands` schema types), the exact inverses of
  the existing `LCF.parse_event_commands` / `LCF.parse_move_commands`
  readers. Previously only scalar and simple-array fields could be edited
  and written back through a schema (`Array1D#[]=`); these two container
  types round-trip now too. Covered by new checks in `mruby-lcf/test/
  lcf_test.rb`.
