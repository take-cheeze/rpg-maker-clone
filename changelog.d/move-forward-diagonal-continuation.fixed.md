- **Move routes:** a Move Forward sub-command following a diagonal move
  (Move Upper-Right/Upper-Left/Lower-Right/Lower-Left) now continues
  diagonally, matching RPG_RT's own `Game_Character::UpdateMoveRoute` --
  its `GetDirection()` is an 8-way value that a diagonal move simply
  leaves set, so Move Forward reuses the same diagonal. Previously it
  collapsed to the diagonal's vertical component only, so a route like
  "Move Upper-Right, Move Forward" veered off the diagonal path onto a
  straight vertical line instead of continuing the diagonal dash.
