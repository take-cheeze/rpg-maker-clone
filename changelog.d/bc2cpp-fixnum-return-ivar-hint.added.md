- **bc2cpp** now proves an ivar embeddable when its source is a call to a
  bare method name already proven whole-program Fixnum-returning
  (`FIXNUM_RETURN_PROOF`), stratified against `IvarLayout` the same way
  `ARRAY_RETURN_PROOF` already is against `ClassLayout` (see ADR 0187).
  Verified against the real project's own 3 compiled gems: 5 new embedded
  ivars (`Game::Screen#@fade_frames`, `Game::Interpreter#@battle_indent`/
  `@choice_indent`/`@inn_indent`/`@shop_indent`), 9 fewer dynamic dispatch
  sites, method-level coverage unchanged at 100.0% (0 `#error`). All 22
  `scripts/bc2cpp_*_check.rb` static checks still pass.
