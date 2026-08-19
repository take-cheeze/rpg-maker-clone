- **XP / VX / VX Ace** `Dir.glob` now works. The vendored `mruby-dir` gem
  never implements it at any layer — only `#each`/`#each_child`/`.foreach`/
  `.open`/`.chdir` — so a real project's stock `DataManager` (the
  Continue-screen check, `Dir.glob('Save0*.rvdata2')`), `Game_System` (a
  shared options file) and a released game's own packed-vs-unpacked check
  (`Dir.glob('Game.rgss3a')`) all failed the script host with
  `NoMethodError` before a single frame drew. Implemented in pure Ruby over
  `Dir.entries` and a glob → `Regexp` translator covering literal names,
  `*`, `?` and `[...]` character classes.
