- **A fire-and-forget (no-wait) Show Battle Animation (11210) now also
  forcibly cuts off a still-playing first one**, instead of being silently
  dropped. `Scene::Map#drive_map_animation`'s "a second Show Battle
  Animation forcibly cuts the first off" fix only ever ran through the
  `:animation` wait dispatch, which a no-wait request never reaches at all
  — it is routed instead through `#apply_battle_animation_request`, which
  still just checked whether the shared `@map_animation`/`@anim_wait` slot
  was free and returned immediately otherwise, permanently losing the
  request rather than displacing whatever already held it. Verified against
  EasyRPG Player's actual C++ source: `Game_Screen::ShowBattleAnimation` is
  a bare unconditional `animation.reset(...)` with no branch on the *new*
  request's own wait flag — only the *issuing* interpreter's resulting wait
  is conditional on that, the cut-off itself is not. Fixed by giving
  `#apply_battle_animation_request` the same unconditional-claim shape
  `#drive_map_animation` already uses: whatever currently owns the slot is
  torn down and immediately resumed before the new fire-and-forget request
  takes it over. Covered by a new `scripts/rpg2k_scene_check.rb` check,
  confirmed to fail against the pre-fix code before the fix.
