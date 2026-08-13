- **Show Battle Animation's sprite is no longer darkened/tinted by an active
  Change Screen Tone.** `@animation_sprite` (`mruby-rpg2k/mrblib/scene/map.rb`,
  the one renderer both a field/parallel-process Show Battle Animation and an
  in-battle attack's own animation share) used to be a child of
  `@map_viewport`, the same viewport `#update_map_tone` tints — so a Tint
  Screen active on the map wrongly washed out every animation play too,
  contradicting yado.tk's "pictures, screen/character flash, battle
  animations, and message text are all completely unaffected even at a
  maximal dark tone." Fixed by making it a top-level sprite (no viewport, so
  no tone reaches it) and splitting the upper (above-character) chip layer
  into its own `@upper_viewport`, tinted in lockstep with `@map_viewport` by
  `#update_map_tone` — needed only so `@animation_sprite` can keep drawing in
  its original slot (over the hero, under the upper chip layer) without
  itself living inside either toned viewport. Covered by two new
  `scripts/rpg2k_scene_check.rb` checks, both confirmed to fail against the
  pre-fix code.
