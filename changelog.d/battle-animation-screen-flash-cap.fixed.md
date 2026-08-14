- A Screen Flash (11040) concurrent with a Battle Animation is now capped to
  the current frame instead of running its own full configured duration,
  matching real RPG_RT: verified against EasyRPG Player's
  `BattleAnimation::Update` (`src/battle_animation.cpp`), which re-asserts
  the screen flash from the animation's own (possibly zero) state on every
  real frame the animation is on screen, silently overwriting anything else.
  `Scene::Map#step_map_animation` (`mruby-rpg2k/mrblib/scene/map.rb`) now
  does the same via a new `#hold_animation_screen_flash`, called every real
  frame the animation drives rather than only on the throttled ticks that
  carry their own flash_scope-2 timing.
