- **`Math` is available to a game's own scripts.** `Game_Character#jump` is stock
  RPG Maker XP and sizes its arc with
  `Math.sqrt(x_plus * x_plus + y_plus * y_plus).round`, so the first jump in any
  game — an event's move route, a Set Move Route command — ended the run with
  `NameError: uninitialized constant Game_Character::Math`. mruby keeps `Math` in
  its own core gem, which this build did not link; it is now in
  `build_config.rb` with the dependency edge that orders its initialization
  before `mruby-rpgxp`, plus an availability test so its absence fails in
  `rake test` rather than in a booted game.
- **`Time` too, ahead of the report.** The stock `Scene_Load` seeds its
  newest-save search with `Time.at(0)` and `Window_SaveFile` stamps each slot
  with `File#mtime`, which answers a `Time` — so every game's save and load
  screens need `mruby-time`, which is only a *test* dependency of `mruby-io` and
  so was not linked. Found by auditing both script bundles for the standard
  library they call rather than waiting for the next boot to name it.
