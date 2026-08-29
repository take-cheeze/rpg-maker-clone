- A Character Flash (Flash Sprite, 11320) concurrent with a Battle Animation
  targeting the same character/enemy is now capped to the current frame the
  same way a concurrent Screen Flash already was, matching real RPG_RT:
  ported from a reference implementation, not independently confirmed
  against genuine RPG_RT under wine, whose animation-update step runs its
  target-flash update unconditionally on every real frame right alongside its
  screen-flash update,
  and always ends in an unconditional flash-the-targets call,
  silently overwriting any other in-flight flash on
  that same target every real frame. `Scene::Map#step_map_animation`
  (`mruby-rpg2k/mrblib/scene/map.rb`) now does the same via a new
  `#hold_animation_target_flash`, called every real frame the animation
  drives (mirroring `#hold_animation_screen_flash`) rather than only on the
  throttled ticks that carry their own flash_scope-1 timing — covering both
  the battle-round path (an enemy sprite's flash, via a new
  `#clear_target_flash`) and the map-triggered path (`@player_flash` / an
  `@events` entry's own `[:flash]`, via a new `#clear_map_target_flash`),
  scoped to just the animation's own target rather than the whole screen.
