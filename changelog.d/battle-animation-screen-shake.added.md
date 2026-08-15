- **A Battle Animation's per-frame `screen_shaking` timing now actually
  shakes**, instead of being decoded and silently dropped. The LCF
  `animation_timing` schema (`mruby-lcf/mrblib/schema.rb`) decodes database
  field 8 as `screen_shaking` (0 none / 1 target / 2 screen), but
  `Scene::Map#fire_animation_flashes` — the loop that already wires up the
  sibling `flash_scope` field — never read it. Verified against EasyRPG
  Player's actual C++ source, `BattleAnimation::ProcessAnimationTiming`
  (`src/battle_animation.cpp`, fetched verbatim): both cases fire a fixed
  `(power 3, speed 5, frames 32)` triple regardless of the timing's own data.
  `screen_shaking` 2 reuses this codebase's existing `Game::Screen#shake` —
  the exact mechanism the Shake Screen event command (11050) already
  drives — with that same triple. `screen_shaking` 1 shakes just the
  animation's own target: a new `Scene::Map#fire_target_shake`/
  `#update_enemy_shakes` ports the same `Shake::NextPosition` sine-wave step
  `Game::Screen#update_shake` already uses to a single battler sprite's own x,
  mirroring EasyRPG's `BattleAnimationBattle`/`BattleAnimationBattler::
  ShakeTargets`; a map-triggered Show Battle Animation's target case is left a
  genuine no-op, matching `BattleAnimationMap::ShakeTargets`'s own empty
  method body in the real source rather than treating it as an oversight to
  fill in. Covered by six new `scripts/rpg2k_scene_check.rb` checks (screen
  and target scope in both the battle-round and map-triggered paths, plus the
  default-0 and no-resolvable-target regression cases).
