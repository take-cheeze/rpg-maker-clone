- **Two below/above-characters map events used to collide with each other,
  and a below/above-characters event could walk straight through a
  same-as-characters one.** `char_passable?`/`char_can_land?` (an event's own
  collision test, driving autonomous/custom-route movement and a Set Move
  Route targeting the player) gated on the *mover's* layer matching the
  blocker's — so two events sharing the same non-`LAYER_SAME` priority (two
  below-characters events, say) collided with each other despite both being
  decorations, while a below/above-characters mover was never blocked by a
  genuinely solid same-as-characters event, only by one sharing its own
  layer. Only `LAYER_SAME` is ever solid, matching the rule `passable?`
  already applies for the hero (see the `LAYER_*` comment): both now check
  the *blocker's* layer alone, independent of the mover's own layer, via the
  same `blockers_at` used by the tile-stacking fix above. `overlap_forbidden`
  is unaffected for a map event mover; the party's own forced Set Move Route
  mirror (`@player_char`) is exempted from it in `char_passable?`/
  `char_can_land?` specifically, since ordinary walking already applies it
  through `passable?` and this is the one path that drives the hero outside
  that. Covered by three new `scripts/rpg2k_scene_check.rb` checks.
