- **Priority type now affects passability, not just draw order.** An event
  page's priority type ("below characters" / "same as characters" / "above
  characters", the `layer` field) already picked which tile buffer an event
  drew into, but every collision check (`passable?`, `char_passable?`,
  `char_can_land?`, `vehicle_passable?`) still blocked movement onto *any*
  event's tile regardless of it — a below/above-characters event (a floor
  decal, a ceiling overlay) could never actually be walked over or under, and
  two events on different priority types could never pass each other, both
  documented RPG_RT behaviours (yado.tk's ツクールの仕様 page). Only
  "same as characters" now blocks: it collides with the hero and with other
  same-layer events, while below/above-characters events are decorations
  everyone walks straight through. `Game::Character` gained a `layer`
  accessor so the movement engine (`Game::MoveRoute` / `Game::MoveType`) can
  see a mover's own priority type, not just the tile it targets. Covered by
  new checks in `scripts/rpg2k_scene_check.rb`.
