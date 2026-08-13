- **A Battle Animation's `position` field (0 head / 1 center / 2 feet) now
  actually offsets where it draws**, instead of being decoded and ignored.
  The LCF `battle_anime` schema (`mruby-lcf/mrblib/schema.rb`, chunk 19 field
  10) already comments the three values; `Scene::Map#build_animation` already
  read `anim.position` into the animation's own state, but nothing downstream
  ever looked at it, so every animation drew centred on its target regardless
  of what it asked for. A new `Scene::Map#animation_position_offset` splits
  symmetrically around the existing centre pixel by half the target's own
  sprite height — `Game::CharSet::HEIGHT` (32px) for a map target (the
  player, a map event or a vehicle, all drawn from a CharSet frame of that
  fixed size), the battler bitmap's real height for an in-battle one — so a
  head-positioned animation now rises and a feet-positioned one sinks,
  instead of both landing on the same pixel as the schema default. A target
  with no known height (the ally-side "middle of the screen" fallback
  `#battle_animation_pixel` returns when RPG2000's front-view battle has no
  sprite to measure) is never offset, which also means every existing caller
  that never learned a height keeps its exact old behaviour. The *direction*
  is confirmed by the schema's own field comment; the exact split RPG_RT
  itself draws at is still approximate pending a wine diff, the same status
  the message window's own relocation zone boundary carries elsewhere in
  this codebase. Covered by new `scripts/rpg2k_scene_check.rb` checks (the
  pure offset math for head/center/feet and a missing height; a battle
  animation's draw position shifting by half the enemy sprite's height for
  head/feet and staying put for center; a map-triggered animation carrying
  the player's `Game::CharSet::HEIGHT`), confirmed to fail against the
  pre-fix code before the fix.
