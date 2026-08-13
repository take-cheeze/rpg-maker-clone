- **A Battle Animation's per-frame target-scope flash (flash_scope 1) now
  actually flashes its target**, instead of being silently dropped.
  `Scene::Map#fire_animation_flashes` only ever handled flash_scope 2 (the
  whole screen); the LCF `animation_timing` schema documents flash_scope as a
  three-way field (0 none / 1 target / 2 screen), and only the screen case
  was wired up. Scoped to a battle-round Show Battle Animation aimed at an
  enemy (a skill/item's `target_index`) — RPG2000's battle is front-view, so
  an ally-targeted entry has no on-screen sprite to flash, and a map-triggered
  Show Battle Animation (11210) aimed at a map character is a different
  target class the Flash Sprite command's own CharSet mechanism already
  models, left unaddressed here. Uses the RGSS `Sprite#flash`/`#update`
  primitive (already ported natively but unused elsewhere in this codebase),
  driven once per frame by a new `Scene::Map#update_enemy_flashes` the same
  way `#update_map_tone` already drives viewport tone. Covered by two new
  `scripts/rpg2k_scene_check.rb` checks (the targeted enemy sprite flashes
  with the LCF colour, decays after its duration, and leaves the screen flash
  and an untargeted bystander sprite untouched; a target-scope timing with no
  resolvable target — an ally, whose battle has no sprite — is a silent
  no-op), the first confirmed to fail against the pre-fix code before the fix.
