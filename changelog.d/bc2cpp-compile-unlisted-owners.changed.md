- **bc2cpp compiles the engine classes no compiled gem listed.** The typed
  save records (`LCF::SaveTyped::*`, 595 methods), `RGSS::Font`,
  `RGSS::HashArchive`, `RGSS::Bitmap::LoadError`, `Game::MoveCommand` and
  `RPG2k.singleton` were on no `owners:` list in
  `tools/bc2cpp/compiled_gems.rb`, so every method of theirs stayed bytecode.
  A `module_function` copy (`LCF.read_ber` and the rest) now registers the
  compiled body on the module's singleton too, when the body never observes
  `self`. `scripts/bc2cpp/compiled_owners_check.rb` fails when an engine class
  with a plain `def` is on no list.
