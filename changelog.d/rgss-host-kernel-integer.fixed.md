- **`Kernel#Integer()` is in the build** (`mruby-kernel-ext`). Every RGSS game
  clamps its battler stats through it — `n = [[Integer(n), 1].max, 999999].min`
  in `Game_Battler_1`, which runs the moment a party member is built — so a game
  running its own scripts died on New Game with "undefined method 'Integer'".
  Covered by an availability test, so it fails in the test binary rather than in
  a player's game.
- A script-host failure now reports **where in the game's own scripts** it
  happened: up to a dozen backtrace frames, named by editor section and line
  (`Game_Battler_1:61`), because each section is evaluated under its own name.
  Past the title screen "Main raised NoMethodError" could otherwise mean any of a
  hundred scripts.
