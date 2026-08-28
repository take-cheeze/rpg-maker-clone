- **A move-route "Move Forward" inside a Begin Jump / End Jump block now
  repeats the diagonal move it directly follows, instead of sliding back
  onto whichever cardinal direction was in hand *before* that diagonal
  ran.** `Game::MoveRoute#jump_move_direction` tracked the jump-scan's
  running direction as a single cardinal value; a diagonal move sub-command
  (Move Upper-Right/Upper-Left/Lower-Right/Lower-Left) fell into the same
  bare `else dir` branch as Move Forward itself, so it left the tracked
  direction completely unchanged — the diagonal step's own displacement was
  still correct (`#jump_delta` computes that straight from the command id,
  not the tracked direction), but a *following* Move Forward in the same
  jump block read the stale pre-diagonal direction instead of continuing
  the diagonal, the mirror image of the (already-fixed) non-jump "Move
  Upper-Right, Move Forward" bug. Fixed by having a diagonal sub-command
  leave its own `[horizontal, vertical]` pair in hand (mirroring
  `Character#last_move_direction`'s existing pair convention outside a
  jump) and teaching `#jump_delta` to compute a diagonal offset from that
  pair when a later Move Forward carries it forward. Covered by a new
  `scripts/rpg2k_logic_check.rb` check (Begin Jump / Move Upper-Right /
  Move Forward / End Jump lands two tiles up-right of start, not one
  up-right plus one back down), confirmed to fail against the pre-fix code
  before the fix.
