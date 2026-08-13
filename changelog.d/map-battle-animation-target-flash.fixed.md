- A map-triggered **Show Battle Animation** (11210) whose flash_scope-1
  ("target") timing pulses a map character now actually flashes it, instead
  of being silently dropped. `Scene::Map#fire_animation_flashes`' flash_scope
  1 case only ever reached `#fire_target_flash`, the in-battle mechanism that
  tones an enemy sprite in `@battle_ui[:enemy_sprites]` — a map scene has no
  battle UI at all, so a map-triggered animation's own target flash simply
  never fired, a gap the target-scope flash fix (see `changelog.d`'s earlier
  battle-animation-target-flash entry) explicitly left open pending its own
  change. `#fire_animation_flashes` now dispatches on the animation's own
  `battle` flag: the enemy-sprite path for a battle round, and a new
  `#fire_map_target_flash` for a map-triggered one — which reuses the Flash
  Sprite command's (11320) own CharSet-tone mechanism (`@player_flash` / an
  `@events` entry's `[:flash]`, already driven every frame by
  `#update_sprite_flashes`) rather than inventing a second one. A new
  `#map_animation_flash_target` resolves the animation's target id the same
  way `#animation_target_pixel` already does for centring the animation
  itself — the player, "this event" (falling back to the player when there
  is none, matching a common event Parallel Process's own animation), or a
  named map event — except a vehicle, which has no Flash Sprite-style tone
  mechanism to hook and stays a silent no-op, the one case
  `#animation_target_pixel` reads a live position for but this cannot flash.
  Covered by three new `scripts/rpg2k_scene_check.rb` checks (a player-
  targeted animation arms `@player_flash` with the timing's scaled colour; a
  named-event-targeted animation arms that event's own flash and never the
  player's; `#map_animation_flash_target`'s own vehicle / unknown-id /
  "this event" decoding), confirmed to fail against the pre-fix code (two
  `RuntimeError`s and a `NoMethodError`) before the fix.
