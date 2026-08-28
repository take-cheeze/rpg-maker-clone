- **A Turn Right / Turn Left / Turn 180 (or the matching half of Turn
  Random) right after a diagonal move-route sub-command now actually
  rotates the diagonal direction a following Move Forward continues in,
  instead of silently collapsing it to a single cardinal axis — the same
  gap cycle #207 closed for the *inside-a-jump-block* case, but in the
  ordinary, non-jump move-route path.** `Character#last_move_direction` is
  what Move Forward reads, and can hold a diagonal `[horizontal, vertical]`
  pair after `#move_diagonal`, but `#turn_right`/`#turn_left`/`#turn_around`
  used to always overwrite it with the freshly-turned *cardinal*
  `@direction` — discarding any diagonal pair outright rather than rotating
  it — so a route like "Move Upper-Right, Turn Right, Move Forward" walked
  the *pre-turn* diagonal collapsed onto one cardinal instead of the turned
  diagonal. `Character::TURN_RIGHT`/`TURN_LEFT`/`TURN_180` already carry the
  diagonal-pair keys cycle #207 added for the identical rotation inside a
  jump block, so the fix reuses them directly: `#last_move_direction` is now
  looked up in the same table (rotating a plain cardinal or a diagonal pair
  alike) instead of being re-derived from `@direction`; the always-cardinal,
  on-screen `@direction` is untouched and keeps rotating exactly as before.
  Covered by two new `scripts/rpg2k_logic_check.rb` checks (Move Upper-Right
  / Turn Right / Move Forward lands at the Down-Right-rotated offset rather
  than the pre-turn diagonal collapsed onto one axis; the same route with
  Turn 180 in place of Turn Right cancels out and lands back at the start,
  as an ordinary non-jump move), both confirmed to fail against the pre-fix
  code before the fix.
