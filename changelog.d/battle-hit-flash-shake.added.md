- **A landed, non-absorbed damaging hit now gets its own automatic flash/
  shake reaction**, independent of whatever Battle Animation the action
  itself plays — or doesn't: a plain enemy Attack against the party resolves
  no animation at all (`Actor#attack_animation_id` has no enemy-side
  counterpart), so it previously landed with zero on-screen feedback beyond
  the banner text and the HP number ticking down. An enemy hit gets the same
  near-white `Sprite#flash` pulse (and `Map::ANIM_FLASH_FRAMES` duration) a
  Battle Animation's own `flash_scope`-1 timing already fires
  (`#fire_target_flash`); a party member's hit gets the same whole-screen
  `Game::Screen#shake` call, at the same `Map::ANIM_SHAKE_POWER`/`SPEED`/
  `FRAMES`, a `screen_shaking`-1 timing already fires — RPG2000's front-view
  battle draws no on-screen ally sprite for a per-sprite reaction to land on,
  so the screen-wide shake stands in for it. No reference-implementation
  call site tying `Flash()`/`ShakeOnce()` to an ordinary damaging hit could be
  found in that implementation's own battle sources, so this reuses the
  codebase's own already-established flash/shake magnitudes rather than
  inventing new ones — not independently confirmed against genuine RPG_RT
  under wine.
