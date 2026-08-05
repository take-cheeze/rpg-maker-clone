- **Move-route jumps hop rather than walk.** `Begin Jump` (24) and `End Jump`
  (25) were treated as plain waits, so the moves between them stepped one tile
  at a time: three route commands where RPG_RT runs one, and each intervening
  tile tested for passability when a jump is precisely the thing that clears
  them. `Game::MoveRoute#do_jump` ports EasyRPG's
  `Game_Character::BeginMoveRouteJump` — the enclosed moves contribute a tile of
  offset each without stepping, the face / turn commands only steer what the
  next move contributes, and the character then lands on the summed destination
  in a single move via the new `Game::Character#jump`, facing the jump's
  dominant axis (vertical winning a tie) rather than its last move. Only the
  landing tile is tested, through a new `can_land?` on the movement world
  (`Scene::Map#char_can_land?`), because the genuine runtime skips the "may I
  leave this tile" half of its check while jumping. A blocked landing behaves
  like a blocked move — retried on a non-skippable route, stepped past on a
  skippable one — and a `Begin Jump` with no `End Jump` unwinds the rest of the
  route, as RPG_RT does. Nepheshel has 625 jump blocks, every one of them
  enclosing a runtime-directed move (484 away from the hero, 188 toward it, 133
  forward) rather than a literal direction; 141 enclose more than one, so those
  now clear the tile they hop over.
