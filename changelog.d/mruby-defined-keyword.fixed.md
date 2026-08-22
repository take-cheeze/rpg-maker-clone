- Fixed a real gap in the vendored mruby compiler: the `defined?` keyword
  (`defined?(expr)` / `defined? expr`) was not implemented at all -- neither
  the lexer nor the grammar recognized it, so it always parsed as an
  ordinary method call and raised `NoMethodError` the moment it was actually
  invoked with a receiver. Found because a real RPG Maker VX Ace game's
  bundled speech-bubble add-on guards a `SceneManager` lookup with
  `defined?(SceneManager)` and crashed on the very first frame it ran. Real,
  not vendor-specific: upstream mruby 3.3.0 has never implemented this
  keyword either. Now answers every expression shape the way real Ruby does
  (`nil`/`true`/`false`/`self`, local variables, assignments, constants,
  methods including operators, instance/class/global variables, `yield`,
  and a generic `"expression"` default), each checked directly against a
  real CRuby interpreter, without ever evaluating anything with side
  effects. Since this project doesn't control the `3rd/mruby` submodule's
  upstream remote, the fix ships as `patches/mruby-defined-keyword.patch`,
  applied idempotently at build time by `scripts/apply_mruby_patch.bash`.
