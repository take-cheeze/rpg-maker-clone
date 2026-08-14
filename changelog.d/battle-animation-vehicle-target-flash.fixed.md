- A map-triggered Show Battle Animation's flash_scope-1 ("target") timing
  aimed at a vehicle (a Move-Event-style target id 10002-10004) now actually
  pulses that vehicle's own on-screen sprite, instead of being silently
  dropped as an unsupported target. Verified against EasyRPG Player's actual
  C++ source: `Game_Character::GetCharacter` (`src/game_character.cpp`)
  resolves `CharBoat`/`CharShip`/`CharAirship` straight to the live
  `Game_Vehicle` object — a `Game_Character` subclass, same as the player or
  a map event — so `BattleAnimationMap::FlashTargets`'s `target->Flash(...)`
  call (`src/battle_animation.cpp`) reaches a vehicle exactly like it reaches
  any other character. `Scene::Map#map_animation_flash_target`
  (`mruby-rpg2k/mrblib/scene/map.rb`) now resolves a vehicle target to its
  own `Game::Vehicle::TYPES` symbol instead of `nil`, and
  `#fire_map_target_flash`/`#clear_map_target_flash` pulse
  `@vehicle_sprites[type]` directly with the native RGSS `Sprite#flash`
  primitive `#fire_target_flash` already uses for a battle enemy sprite — a
  vehicle already draws through a real `Sprite`, so it needs no CharSet-tint
  mechanism the way the player/map-event case does. A new
  `#update_vehicle_flashes`, called every real frame from `#update`,
  decays it the same way `#update_enemy_flashes` already does for battle
  enemy sprites — without it, a vehicle's flash would have stayed at full
  intensity forever once armed, since nothing ever called `Sprite#update` on
  a vehicle sprite before this fix.
