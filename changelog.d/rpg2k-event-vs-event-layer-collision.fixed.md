- **`overlap_forbidden` (LCF page field 35, "doesn't overlap another event")
  used to block the hero too, and event-vs-event layer collision briefly
  regressed to "only a same-as-characters blocker is ever solid" while this
  fix was in progress.** Checked against a reference implementation's actual
  collision logic (ported from a reference implementation, not independently
  confirmed against genuine RPG_RT under wine): `overlap_forbidden` only
  ever collides two *map events* — both sides must be an event, and the flag
  is set on either of them — the party's own type is never an event, so the
  flag can never be what blocks the hero, on either side of the collision,
  regardless of layer. Layer itself gates collision on an *exact* match
  between both sides' priority type, not on either side being `LAYER_SAME`
  specifically — two below-characters events collide with each other
  exactly as two same-characters ones do, and only a mismatched pair (below
  vs. above, below vs. same, …) passes through. The hero's own layer is
  always effectively `LAYER_SAME` (the player character never overrides its
  layer type), so the same exact-match rule already produces "only a
  same-as-characters event blocks the hero" for hero collision with no
  special-casing needed. `passable?` (the hero's own step), `char_passable?`
  and `char_can_land?` (an event's own movement, or the party's forced Set
  Move Route mirror) now match this precisely: `overlap_forbidden` is
  checked on *either* side (`character.overlap_forbidden ||
  b[:overlap_forbidden]`) but only between two events, layer collision is an
  exact match on both sides' `layer`, and the hero — walking ordinarily or
  under a forced route alike — is never blocked by `overlap_forbidden` at
  all. Covered by `scripts/rpg2k_scene_check.rb` checks for every corner:
  two below-characters events still collide with each other; a below-layer
  mover crosses a same-layer blocker (mismatched layers); `overlap_forbidden`
  does not stop the hero on an ordinary step or from a below-layer event
  walking onto the hero's own tile, while it still stops a mismatched-layer
  event.
