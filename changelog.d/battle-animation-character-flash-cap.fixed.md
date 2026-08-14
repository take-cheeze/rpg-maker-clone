- A Character Flash (Flash Sprite, 11320) concurrent with a Battle Animation
  targeting the same character/enemy is now capped to the current frame the
  same way a concurrent Screen Flash already was, matching real RPG_RT:
  verified against EasyRPG Player's `BattleAnimation::Update`
  (`src/battle_animation.cpp`), which calls `UpdateTargetFlash()`
  unconditionally on every real frame right alongside `UpdateScreenFlash()`,
  and always ends in an unconditional `FlashTargets(r, g, b, p)` —
  `BattleAnimationMap`/`BattleAnimationBattle`'s own `target->Flash(...)` /
  `battler->Flash(...)` — silently overwriting any other in-flight flash on
  that same target every real frame. `Scene::Map#step_map_animation`
  (`mruby-rpg2k/mrblib/scene/map.rb`) now does the same via a new
  `#hold_animation_target_flash`, called every real frame the animation
  drives (mirroring `#hold_animation_screen_flash`) rather than only on the
  throttled ticks that carry their own flash_scope-1 timing — covering both
  the battle-round path (an enemy sprite's flash, via a new
  `#clear_target_flash`) and the map-triggered path (`@player_flash` / an
  `@events` entry's own `[:flash]`, via a new `#clear_map_target_flash`),
  scoped to just the animation's own target rather than the whole screen.
