- **bc2cpp's compiled gems no longer list their owners by hand.** Each gem's
  `owners:` in `tools/bc2cpp/compiled_gems.rb` is now read from its base gem's
  mrblib (`tools/bc2cpp/gem_owners.rb`): every engine class or module with a
  plain `def`, its singleton for `def self.`/`class << self` and for a
  `module_function` module, and the core classes the gem reopens (`Array`,
  `StringIO`). A new engine class is compiled without editing the table. The
  hand lists had also picked up words from comments written inside `%w[...]`
  and a stale `Game::Picture.singleton`.
