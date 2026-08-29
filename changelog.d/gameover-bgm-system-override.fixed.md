- **The Game Over screen now honours a Change System BGM override for the
  game-over slot.** `Scene::GameOver#play_gameover_bgm` used to always play
  the database's own `gameover_music`, ignoring a Change System BGM (10660)
  override the event system already stashed on `Game::State#system_bgm`
  (slot 6 is game over, ported from a reference implementation's own
  game-over BGM slot, not independently confirmed against genuine RPG_RT
  under wine). `Game::State` was not even reachable
  from the screen before this — `RPG2k#show_game_over` and
  `Scene::GameOver.new` took no state argument at all, since the whole scene
  stack (and the `Game::State` living on it) is normally gone by the time a
  game-over defeat replaces it — so `Scene::Map#perform_game_over` now
  passes its own `@state` through `show_game_over` to the new screen, which
  resolves the override first and falls back to the database default,
  mirroring that same reference's own "override wins only when its own name
  is non-empty" rule. The parameter is optional and defaults to `nil`
  (falling back to the database default unconditionally, unchanged from
  before) so the Game Over event command's own reach into this path, and
  every pre-existing bare-fixture caller, keep working. Covered by three new
  `scripts/rpg2k_scene_check.rb` checks (an override plays instead of the
  database music; omitting the state argument still falls back to the
  database default; a game-over battle defeat hands the screen the very
  `Game::State` the battle ran on), confirmed to fail against the pre-fix
  code before the fix.
