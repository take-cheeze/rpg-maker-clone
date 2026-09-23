- The 17 `Struct.new` records in `mruby-rpg2k/mrblib` (`MapEventState`,
  `MessageState`, `ShopState`, `ShopQuantity`, `Game::Battle::Combatant`,
  the interpreter's wait requests, `DiagnosticPosition`,
  `CommonEventRecord` and the message-scan records) are plain classes with
  `attr_accessor`s and an explicit `#initialize`, and every `x[:member]`
  access on them is `x.member`. bc2cpp now sees each accessor and keeps the
  Integer/boolean/Symbol fields of 16 of them as typed struct fields: on
  Nepheshel's 258-event map 114, instructions per frame drop 11% under
  callgrind, and the `-Os` text of `mruby-rpg2k-compiled` shrinks 3.1%.
  Game behaviour is unchanged. See docs/adr/0215.
