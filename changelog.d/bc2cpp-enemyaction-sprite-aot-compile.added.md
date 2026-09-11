- The opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler now also covers all six of
  `Game::EnemyAction`'s own real bytecode methods (added to
  `mruby-rpg2k-compiled`, alongside `Game::Picture`) and all 17 of
  `RGSS::Sprite`'s own plain-Ruby reader methods (a new `mruby-rgss-compiled`
  gem). Getting there needed two new opcodes in `tools/bc2cpp/bc2cpp.rb`
  (`JMPNIL`, a nil-check branch; `LOADL`, a float-pool literal too wide for
  `LOADI`'s immediate operand) and a `GETCONST` fix: it only ever tried the
  `Object` scope for a bare constant, wrong whenever the constant is
  defined on its own enclosing module instead (`RGSS::Sprite#tone`'s own
  `Tone.new`) -- now walks the owner's real lexical nesting chain first.
  See `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`.
