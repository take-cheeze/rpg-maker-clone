- **Set Vehicle Location (10850)** and **Change Vehicle Graphic (10650).** The two
  event commands that manipulate a vehicle now drive the existing `Game::Vehicle`
  model. Set Vehicle Location places the boat / ship / airship on a map — param0
  selects the vehicle, param1 the operand mode (literal values or variable ids,
  like Change Event Location's designation) and param2/param3/param4 the map id,
  x and y. Change Vehicle Graphic gives a vehicle a new CharSet (command string =
  file, param1 = cell). Both persist through the save that already round-trips
  vehicle state, and an out-of-range vehicle id is a no-op. Boarding and piloting
  a vehicle are still to come. Covered by new checks in
  `scripts/rpg2k_logic_check.rb` (placing in literal and variable modes, setting
  the graphic, an out-of-range no-op, and a placement + graphic round-trip through
  the save).
