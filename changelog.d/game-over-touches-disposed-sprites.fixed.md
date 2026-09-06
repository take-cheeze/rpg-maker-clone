- **A battle loss that ends the game no longer crashes the moment the Game
  Over screen comes up.** `RPG2k#show_game_over` (and `#return_to_title`)
  dispose every scene on `@scenes` — this `Scene::Map` included — the instant
  Game Over is reached, and `Scene::Map#perform_game_over` reaches it
  synchronously from inside the very `Scene::Map#update` call that is still
  running: `#drive_event`'s own `:game_over`/`:return_title` dispatch calls it
  directly, mid-frame, not after. `#update` used to plough on regardless into
  that same frame's own event stepping, `#animate_events` and `#render`,
  which touch this scene's own sprites and viewports (`#render`'s
  `#apply_player_visibility` sets `@player_sprite.visible`, among others) —
  now pointing at LVGL objects `#dispose` already freed. The native sprite
  setters (`mruby-rgss/src/lib.cxx`'s `obj_set_x`/`obj_set_y`/
  `obj_set_visible`) assert their object is non-null and abort the whole
  process outright on a party wipe, exactly the crash reported: `[RPG2k]
  game over` printed, then `Assertion 'obj' failed. Aborted (core dumped)`.
  `Scene::Map` now tracks its own `@disposed` flag (set at the top of
  `#dispose`) and bails out of `#update` the instant it notices — right after
  the parallel-process step (`#drive_parallel_wait` can reach Game Over too)
  and right after the foreground/autostart event step — before touching any
  sprite again. Covered by a new `scripts/rpg2k_scene_check.rb` check
  (overriding the test harness's own `FakeParent#show_game_over`, which only
  records the call, to actually dispose the scene the way the real one does),
  confirmed to fail against the pre-fix code with the exact native assertion
  mirrored as a Ruby exception.
